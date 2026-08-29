// lib/ui/repo_screen.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files/file_path_rules.dart';
import '../files/file_tree.dart';
import '../files/repo_file_ops.dart';
import '../git/git_identity.dart';
import '../git/repo_git_service.dart';
import '../github/github_api.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';

/// One cloned repository: its branch, its pending changes, its files, and
/// every git action that can be run against it.
///
/// There is no chat log in this app, so every result — a status listing, a
/// push failure, a confirmation — lands in one of the three popups from
/// [app_theme]. The single rule that holds all of it together is
/// [_runGitAction]: no code path may swallow an error, and no code path may
/// let the personal access token reach the screen.
class RepoScreen extends StatefulWidget {
  final GithubRepo repo;
  final Directory repoDir;
  final SecretStore secretStore;

  const RepoScreen({
    super.key,
    required this.repo,
    required this.repoDir,
    required this.secretStore,
  });

  @override
  State<RepoScreen> createState() => _RepoScreenState();
}

class _RepoScreenState extends State<RepoScreen> {
  /// A git operation is in flight. Disables the action bar so two pushes
  /// cannot overlap on the same clone.
  bool _busy = false;

  String _branch = '';
  List<String> _uncommitted = const [];
  FileTreeNode? _tree;

  /// Directories the user has unfolded, by relativePath. Everything below the
  /// root starts collapsed — a repo with a node_modules in it should not open
  /// as a thousand-row list.
  final Set<String> _expandedDirs = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<RepoGitService> _gitService() async =>
      RepoGitService(reposRoot: await getApplicationDocumentsDirectory());

  /// Re-reads branch, pending changes and file tree. Called on open and after
  /// anything that could have changed the working tree.
  Future<void> _refresh() async {
    try {
      final service = await _gitService();
      final branch = await service.currentBranchName(widget.repoDir);
      final paths = await service.uncommittedPaths(widget.repoDir);
      final tree = await buildFileTree(widget.repoDir);
      if (!mounted) return;
      setState(() {
        _branch = branch;
        _uncommitted = paths;
        _tree = tree;
      });
    } catch (_) {
      // ponytail: a refresh that fails leaves the last good view standing.
      // The Status chip reports the real reason in full, and a popup per
      // background refresh would fire on every action instead.
    }
  }

  // -----------------------------------------------------------------------
  // The error funnel.
  // -----------------------------------------------------------------------

  /// Runs one git action and shows whatever comes back — the returned lines,
  /// our own refusal, or the raw failure — always with the token scrubbed out
  /// of the message first.
  ///
  /// [offerRetryPush] is for the commit flow: when the commit lands but the
  /// push does not, re-running the whole commit would be wrong, so the user
  /// is offered a bare push instead.
  Future<void> _runGitAction(
    String title,
    Future<List<String>> Function(RepoGitService service, Directory dir, String? token) run, {
    bool offerRetryPush = false,
  }) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    // Read up front purely so the catch blocks can scrub it out of whatever
    // libgit2 says. It is never rendered, only searched for.
    String? token;
    var failed = false;
    try {
      token = await widget.secretStore.read(secretKeyGithubPat);
      final service = await _gitService();
      final lines = await run(service, widget.repoDir, token);
      if (!mounted) return;
      await showOutputPopup(
        context,
        title: title,
        body: truncateLines(lines).join('\n'),
      );
    } on StateError catch (e) {
      // Our own refusals (nothing to commit, dirty tree, not a fast-forward)
      // are already written for a human — show the message as it stands.
      if (!mounted) return;
      await showOutputPopup(context, title: title, body: redactSecrets(e.message, token: token));
    } catch (e) {
      // Lead with what the user can do about it, never instead of the real
      // error, which still follows verbatim minus anything token-shaped.
      failed = true;
      final raw = redactSecrets('$e', token: token);
      final help = githubAuthHelp(raw);
      if (!mounted) return;
      await showOutputPopup(
        context,
        title: '$title failed',
        body: help == null ? raw : '$help\n\n$raw',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
    if (failed && offerRetryPush && mounted) await _offerRetryPush();
  }

  String _requireToken(String? token) {
    if (token == null || token.isEmpty) {
      throw StateError('No GitHub token — connect your GitHub account in Settings.');
    }
    return token;
  }

  Future<void> _offerRetryPush() async {
    final retry = await showConfirmPopup(
      context,
      title: 'Retry push?',
      message: 'If the commit was created but the push failed, this pushes the '
          'current branch again without committing anything new.',
      confirmLabel: 'Retry push',
      cancelLabel: 'Close',
    );
    if (!retry || !mounted) return;
    await _runGitAction(
      '\$ git push',
      (service, dir, token) async => [
        await service.pushCurrentBranch(repoDir: dir, token: _requireToken(token)),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Read-only chips.
  // -----------------------------------------------------------------------

  Future<void> _gitStatus() => _runGitAction(
        '\$ git status',
        (service, dir, _) => service.statusLines(dir),
      );

  Future<void> _gitLog() => _runGitAction(
        '\$ git log -10',
        (service, dir, _) async => formatLogLines(await service.recentCommits(dir, limit: 10)),
      );

  Future<void> _gitDiff({String? relativePath}) => _runGitAction(
        relativePath == null ? '\$ git diff' : '\$ git diff -- $relativePath',
        (service, dir, _) async {
          final lines = await service.diffLines(dir, relativePath: relativePath);
          return lines.isEmpty ? const ['no changes'] : lines;
        },
      );

  Future<void> _gitPull() => _runGitAction(
        '\$ git pull --ff-only',
        (service, dir, token) async => [
          await service.pullFastForward(repoDir: dir, token: _requireToken(token)),
        ],
      );

  /// Answers the "why did that push 403?" question definitively, over the
  /// REST API — libgit2 only ever reports the status code.
  Future<void> _checkAccess() => _runGitAction(
        'Check access',
        (service, dir, token) => GithubApi(client: Dio(), token: _requireToken(token))
            .checkAccess(widget.repo.fullName),
      );

  // -----------------------------------------------------------------------
  // Commit & push.
  // -----------------------------------------------------------------------

  /// [paths] null commits everything pending; a list commits exactly those
  /// paths. Both stop at the same confirmation, because both publish to a
  /// real GitHub repository.
  Future<void> _commitAndPush({List<String>? paths}) async {
    if (_busy) return;
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      await showOutputPopup(
        context,
        title: 'Not connected',
        body: 'No GitHub token stored.\n\nConnect your GitHub account in '
            'Settings, then try again.',
      );
      return;
    }

    final identity = await loadCommitIdentity(await SharedPreferences.getInstance());
    if (!mounted) return;
    if (identity == null) {
      await showOutputPopup(
        context,
        title: 'Not signed in',
        body: 'Commits are authored by the signed-in GitHub account, and no '
            'account is connected.\n\nConnect GitHub in Settings, then try again.',
      );
      return;
    }

    final targets = paths ?? _uncommitted;
    final message = await _askCommitMessage(targets);
    if (message == null || !mounted) return;

    await _runGitAction(
      '\$ git commit && git push',
      (service, dir, _) async => [
        paths == null
            ? await service.commitAllAndPush(
                repoDir: dir,
                message: message,
                token: token,
                identity: identity,
              )
            : await service.commitFilesAndPush(
                repoDir: dir,
                relativePaths: paths,
                message: message,
                token: token,
                identity: identity,
              ),
      ],
      offerRetryPush: true,
    );
  }

  /// The last stop before something leaves the phone: the repo, the branch,
  /// and every path about to be committed, above an editable message.
  Future<String?> _askCommitMessage(List<String> paths) async {
    const fallback = 'Update from PocketGit';
    // The controller belongs to the route, not to this method: disposing it
    // when showDialog's future completes kills the field that is still
    // rebuilding through the close animation.
    return showDialog<String>(
      context: context,
      builder: (ctx) => AppControllerScope(
        initialText: fallback,
        builder: (ctx, controller) => AlertDialog(
          backgroundColor: AppColors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppColors.fg, width: 2),
          ),
          title: Text('Commit & push?', style: appHeading(size: 16)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${widget.repo.fullName} · $_branch', style: appMono(size: 12)),
                const SizedBox(height: 10),
                Text(
                  paths.isEmpty
                      ? 'Nothing is pending — git will refuse this.'
                      : '${paths.length} path(s):',
                  style: appBody(size: 12.5, color: AppColors.muted),
                ),
                const SizedBox(height: 6),
                // Capped so a 200-file commit cannot push the buttons off
                // screen; the list scrolls inside the box instead.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: SingleChildScrollView(
                    child: Text(
                      truncateLines(paths, max: 60).join('\n'),
                      style: appMono(size: 11.5),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                appBorderedField(controller: controller, hint: 'Commit message'),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            Row(
              children: [
                // Full-width SizedBoxes: unwrapped in a Row they blow the
                // dialog's constraints.
                Expanded(
                  child: appSecondaryButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: appPrimaryButton(
                    label: 'Push',
                    onPressed: () {
                      final text = controller.text.trim();
                      Navigator.of(ctx).pop(text.isEmpty ? fallback : text);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Branches.
  // -----------------------------------------------------------------------

  Future<void> _openBranchPopup() async {
    if (_busy) return;
    final List<String> lines;
    try {
      final service = await _gitService();
      lines = await service.branchLines(widget.repoDir);
    } catch (e) {
      if (!mounted) return;
      await showOutputPopup(context, title: 'Branches', body: redactSecrets('$e'));
      return;
    }
    if (!mounted) return;

    // branchLines marks the checked-out one with "* "; the name is what is
    // left after that two-character prefix.
    final choice = await _chooseAction(
      title: 'Branches',
      subtitle: widget.repo.fullName,
      options: [
        for (final line in lines)
          if (!line.trim().startsWith('('))
            (value: line.substring(2), label: line.trim(), icon: line.startsWith('*') ? Icons.check : Icons.call_split),
        (value: _newBranchAction, label: 'New branch…', icon: Icons.add),
      ],
    );
    if (choice == null || !mounted) return;

    if (choice == _newBranchAction) {
      final name = await showInputPopup(
        context,
        title: 'New branch',
        hint: 'feature/notes',
        confirmLabel: 'Create',
        description: 'Created off the current branch and checked out.',
      );
      if (name == null || !mounted) return;
      await _runGitAction(
        '\$ git checkout -b $name',
        (service, dir, _) async => [
          await service.createBranch(repoDir: dir, name: name, checkout: true),
        ],
      );
      return;
    }
    if (choice == _branch) return; // already on it
    await _runGitAction(
      '\$ git checkout $choice',
      (service, dir, _) async => [await service.checkoutBranch(repoDir: dir, name: choice)],
    );
  }

  /// Sentinel for the "New branch…" row. Two spaces: a git ref name cannot
  /// contain one, so it can never collide with a real branch.
  static const _newBranchAction = '  new-branch';

  // -----------------------------------------------------------------------
  // Files.
  // -----------------------------------------------------------------------

  /// The popup behind an uncommitted-changes chip.
  Future<void> _openUncommittedPath(String relativePath) async {
    final choice = await _chooseAction(
      title: 'Uncommitted change',
      subtitle: relativePath,
      options: const [
        (value: 'edit', label: 'Edit', icon: Icons.edit_note),
        (value: 'diff', label: 'Diff', icon: Icons.difference_outlined),
        (value: 'discard', label: 'Discard changes', icon: Icons.undo),
        (value: 'delete', label: 'Delete file', icon: Icons.delete_outline),
      ],
    );
    if (choice == null || !mounted) return;

    switch (choice) {
      case 'edit':
        await _openFile(relativePath);
      case 'diff':
        await _gitDiff(relativePath: relativePath);
      case 'discard':
        final ok = await showConfirmPopup(
          context,
          title: 'Discard changes?',
          detail: relativePath,
          message: 'Restores this path to the last commit. Uncommitted work in '
              'it is destroyed and cannot be recovered from here.',
          confirmLabel: 'Discard',
          cancelLabel: 'Keep',
        );
        if (!ok || !mounted) return;
        await _runGitAction(
          '\$ git checkout -- $relativePath',
          (service, dir, _) async {
            await service.discardChanges(repoDir: dir, relativePath: relativePath);
            return ['Discarded local changes to $relativePath.'];
          },
        );
      case 'delete':
        await _deleteFile(relativePath);
    }
  }

  /// Opens one file for editing. The content is read *before* the dialog
  /// opens, so a read failure is a popup rather than an empty editor
  /// pretending the file is blank.
  Future<void> _openFile(String relativePath) async {
    try {
      if (await looksBinary(widget.repoDir, relativePath)) {
        if (!mounted) return;
        await showOutputPopup(
          context,
          title: 'Binary file',
          body: '$relativePath is not text.\n\nPocketGit will not open it in '
              'the editor — saving it back would corrupt it.',
        );
        return;
      }
      final content = await readRepoFile(widget.repoDir, relativePath);
      if (!mounted) return;
      await _showEditor(relativePath, content);
    } catch (e) {
      if (!mounted) return;
      await showOutputPopup(
        context,
        title: 'Could not open file',
        body: '$relativePath\n\n${redactSecrets('$e')}',
      );
    }
  }

  Future<void> _showEditor(String relativePath, String content) async {
    // The dialog hands back (action, text) rather than leaving the text to be
    // read off a controller afterwards: the route owns the controller and
    // disposes it as it closes, so by the time this method resumes there is
    // nothing left to read.
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AppControllerScope(
        initialText: content,
        builder: (ctx, controller) => AlertDialog(
          backgroundColor: AppColors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppColors.fg, width: 2),
          ),
          title: Text('Edit file', style: appHeading(size: 16)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(relativePath, style: appMono(size: 12)),
                const SizedBox(height: 10),
                // maxLines caps the height and lets the field scroll inside
                // it, so a 2000-line file cannot push the buttons off screen.
                appBorderedField(controller: controller, hint: 'File content', maxLines: 12),
                const SizedBox(height: 10),
                Row(
                  children: [
                    appActionChip(
                      icon: Icons.drive_file_rename_outline,
                      label: 'Rename',
                      onPressed: () => Navigator.of(ctx).pop(('rename', controller.text)),
                    ),
                    const SizedBox(width: 8),
                    appActionChip(
                      icon: Icons.delete_outline,
                      label: 'Delete',
                      onPressed: () => Navigator.of(ctx).pop(('delete', controller.text)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            Row(
              children: [
                Expanded(
                  child: appSecondaryButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: appPrimaryButton(
                    label: 'Save',
                    onPressed: () => Navigator.of(ctx).pop(('save', controller.text)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    final action = result?.$1;
    final editedText = result?.$2 ?? content;

    if (action == 'save') {
      try {
        await writeRepoFile(widget.repoDir, relativePath, editedText);
        await _refresh();
        if (!mounted) return;
        await showOutputPopup(
          context,
          title: 'Saved',
          body: '$relativePath — local clone only.\n\nCommit & push to '
              'publish it to GitHub.',
        );
      } catch (e) {
        if (!mounted) return;
        await showOutputPopup(
          context,
          title: 'Could not save',
          body: '$relativePath\n\n${redactSecrets('$e')}',
        );
      }
    }

    if (!mounted) return;
    if (action == 'delete') {
      await _deleteFile(relativePath);
    } else if (action == 'rename') {
      await _renameFile(relativePath);
    }
  }

  Future<void> _renameFile(String from) async {
    final to = await showInputPopup(
      context,
      title: 'Rename file',
      hint: 'docs/notes.md',
      initial: from,
      confirmLabel: 'Rename',
      description: 'New repo-relative path.',
      validator: filePathRejection,
    );
    if (to == null || !mounted) return;
    final target = normaliseFilePath(to);
    if (target == from) return;
    try {
      if (await repoFileExists(widget.repoDir, target)) {
        if (!mounted) return;
        final ok = await showConfirmPopup(
          context,
          title: 'Overwrite?',
          detail: target,
          message: 'A file already exists at that path. Renaming onto it '
              'replaces its contents.',
          confirmLabel: 'Overwrite',
        );
        if (!ok) return;
      }
      await renameRepoFile(widget.repoDir, from, target, overwrite: true);
      await _refresh();
      if (!mounted) return;
      await showOutputPopup(context, title: 'Renamed', body: '$from\n  ->  $target');
    } catch (e) {
      if (!mounted) return;
      await showOutputPopup(context, title: 'Could not rename', body: redactSecrets('$e'));
    }
  }

  /// Deleting destroys work that may not be committed anywhere, so it always
  /// stops for a yes first.
  Future<void> _deleteFile(String relativePath) async {
    final ok = await showConfirmPopup(
      context,
      title: 'Delete this file?',
      detail: relativePath,
      message: 'Removes it from the local clone. If it was never committed, '
          'this cannot be undone from here.',
      confirmLabel: 'Delete',
      cancelLabel: 'Keep',
    );
    if (!ok || !mounted) return;
    try {
      await deleteRepoFile(widget.repoDir, relativePath);
      await _refresh();
      if (!mounted) return;
      await showOutputPopup(
        context,
        title: 'Deleted',
        body: '$relativePath removed from the local clone.\n\nCommit & push to '
            'delete it on GitHub too.',
      );
    } catch (e) {
      if (!mounted) return;
      await showOutputPopup(context, title: 'Could not delete', body: redactSecrets('$e'));
    }
  }

  /// The headline feature: path, then content, then an offer to push it.
  Future<void> _newFile() async {
    final typed = await showInputPopup(
      context,
      title: 'New file',
      hint: 'docs/notes.md',
      confirmLabel: 'Next',
      description: 'Repo-relative path inside ${widget.repo.fullName}.',
      validator: filePathRejection,
    );
    if (typed == null || !mounted) return;
    final relativePath = normaliseFilePath(typed);

    try {
      if (await repoFileExists(widget.repoDir, relativePath)) {
        if (!mounted) return;
        final ok = await showConfirmPopup(
          context,
          title: 'Overwrite?',
          detail: relativePath,
          message: 'That file already exists in this clone. Continuing '
              'replaces its contents.',
          confirmLabel: 'Overwrite',
        );
        if (!ok) return;
      }
    } catch (e) {
      if (!mounted) return;
      await showOutputPopup(context, title: 'Could not check path', body: redactSecrets('$e'));
      return;
    }
    if (!mounted) return;

    // ponytail: showInputPopup refuses empty input, so a deliberately empty
    // file cannot be created here. Add a dedicated "create empty" path only
    // if someone actually asks for one.
    final content = await showInputPopup(
      context,
      title: relativePath,
      hint: 'File content',
      confirmLabel: 'Create',
      maxLines: 10,
    );
    if (content == null || !mounted) return;

    try {
      await writeRepoFile(widget.repoDir, relativePath, content);
    } catch (e) {
      if (!mounted) return;
      await showOutputPopup(context, title: 'Could not create file', body: redactSecrets('$e'));
      return;
    }
    await _refresh();
    if (!mounted) return;

    final push = await showConfirmPopup(
      context,
      title: 'Commit & push now?',
      detail: relativePath,
      message: 'Created in the local clone. Commit just this file and push it '
          'to $_branch on GitHub?',
      confirmLabel: 'Commit & push',
      cancelLabel: 'Later',
    );
    if (!push || !mounted) return;
    await _commitAndPush(paths: [relativePath]);
  }

  Future<void> _importFile() async {
    final picked = await FilePicker.platform.pickFiles();
    final source = picked?.files.single.path;
    if (source == null || !mounted) return;

    final typed = await showInputPopup(
      context,
      title: 'Import file',
      hint: 'assets/logo.png',
      initial: p.basename(source),
      confirmLabel: 'Import',
      description: 'Where to put it inside ${widget.repo.fullName}.',
      validator: filePathRejection,
    );
    if (typed == null || !mounted) return;
    final target = normaliseFilePath(typed);

    try {
      if (await repoFileExists(widget.repoDir, target)) {
        if (!mounted) return;
        final ok = await showConfirmPopup(
          context,
          title: 'Overwrite?',
          detail: target,
          message: 'That path already exists in this clone.',
          confirmLabel: 'Overwrite',
        );
        if (!ok) return;
      }
      await importFileInto(widget.repoDir, source, target);
      await _refresh();
      if (!mounted) return;
      await showOutputPopup(
        context,
        title: 'Imported',
        body: '$source\n  ->  $target\n\nLocal clone only — commit & push to '
            'publish it.',
      );
    } catch (e) {
      if (!mounted) return;
      await showOutputPopup(context, title: 'Could not import', body: redactSecrets('$e'));
    }
  }

  // -----------------------------------------------------------------------
  // Widgets.
  // -----------------------------------------------------------------------

  /// A list of chips in a popup, one of which is returned. Covers both the
  /// branch list and the per-file action menu — same shape, same frame.
  Future<String?> _chooseAction({
    required String title,
    required String subtitle,
    required List<({String value, String label, IconData icon})> options,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
        title: Text(title, style: appHeading(size: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle, style: appMono(size: 12)),
                const SizedBox(height: 12),
                for (final option in options) ...[
                  appActionChip(
                    icon: option.icon,
                    label: option.label,
                    onPressed: () => Navigator.of(ctx).pop(option.value),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Row(
            children: [
              Expanded(
                child: appSecondaryButton(
                  label: 'Close',
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          appIconCircleButton(
            icon: Icons.arrow_back,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.repo.fullName,
              style: appHeading(size: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          appActionChip(
            icon: Icons.call_split,
            label: _branch.isEmpty ? widget.repo.defaultBranch : _branch,
            onPressed: _busy ? null : _openBranchPopup,
          ),
        ],
      ),
    );
  }

  /// Horizontally scrollable so a narrow phone scrolls the row rather than
  /// overflowing it.
  Widget _gitActionsBar() {
    final chips = <Widget>[
      appActionChip(icon: Icons.difference_outlined, label: 'Status', onPressed: _busy ? null : _gitStatus),
      appActionChip(icon: Icons.history, label: 'Log', onPressed: _busy ? null : _gitLog),
      appActionChip(icon: Icons.compare_arrows, label: 'Diff', onPressed: _busy ? null : _gitDiff),
      appActionChip(icon: Icons.call_split, label: 'Branches', onPressed: _busy ? null : _openBranchPopup),
      appActionChip(icon: Icons.south, label: 'Pull', onPressed: _busy ? null : _gitPull),
      appActionChip(
        icon: Icons.cloud_upload_outlined,
        label: 'Commit & push',
        emphasis: true,
        onPressed: _busy ? null : () => _commitAndPush(),
      ),
      appActionChip(
        icon: Icons.verified_user_outlined,
        label: 'Check access',
        onPressed: _busy ? null : _checkAccess,
      ),
    ];
    return SizedBox(
      height: 46,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            for (final chip in chips) ...[chip, const SizedBox(width: 8)],
          ],
        ),
      ),
    );
  }

  /// One chip per uncommitted path. Basenames only — the full path is in the
  /// tooltip and in the popup behind it.
  Widget _uncommittedBar() {
    return SizedBox(
      height: 46,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Text('Uncommitted', style: appMono(size: 11, color: AppColors.muted)),
            const SizedBox(width: 8),
            for (final path in _uncommitted) ...[
              Tooltip(
                message: path,
                child: appActionChip(
                  icon: Icons.edit_note,
                  label: path.split('/').last,
                  onPressed: _busy ? null : () => _openUncommittedPath(path),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _fileTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      final expanded = child.isDirectory && _expandedDirs.contains(child.relativePath);
      tiles.add(InkWell(
        onTap: child.isDirectory
            ? () => setState(() {
                  if (!_expandedDirs.remove(child.relativePath)) {
                    _expandedDirs.add(child.relativePath);
                  }
                })
            : () => _openFile(child.relativePath),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12 + depth * 16.0, 8, 12, 8),
          child: Row(
            children: [
              // Files keep the same left edge as their sibling folders.
              SizedBox(
                width: 15,
                child: child.isDirectory
                    ? Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        size: 15,
                        color: AppColors.fg,
                      )
                    : null,
              ),
              const SizedBox(width: 4),
              Icon(
                child.isDirectory ? Icons.folder_outlined : Icons.description_outlined,
                size: 15,
                color: child.isDirectory ? AppColors.fg : AppColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(child.name, style: appMono(size: 12), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ));
      if (expanded) tiles.addAll(_fileTiles(child, depth + 1));
    }
    return tiles;
  }

  @override
  Widget build(BuildContext context) {
    final tree = _tree;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            _gitActionsBar(),
            if (_uncommitted.isNotEmpty) _uncommittedBar(),
            const Divider(height: 1, color: AppColors.divider),
            Expanded(
              child: tree == null
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg),
                      ),
                    )
                  : tree.children.isEmpty
                      ? Center(
                          child: Text('This repository is empty.',
                              style: appBody(size: 13, color: AppColors.muted)),
                        )
                      : ListView(children: _fileTiles(tree, 0)),
            ),
            const Divider(height: 1, color: AppColors.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: appPrimaryButton(label: 'New file', onPressed: _busy ? null : _newFile),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: appSecondaryButton(label: 'Import file', onPressed: _busy ? null : _importFile),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
