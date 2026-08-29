// lib/ui/repos_screen.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../git/repo_git_service.dart';
import '../git/repo_paths.dart';
import '../github/github_repo.dart';
import '../github/repo_browser_service.dart';
import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';
import 'repo_screen.dart';

/// The first tab: every repository the stored token can see, and whether it
/// is on this device yet.
class ReposScreen extends StatefulWidget {
  final SecretStore secretStore;
  final VoidCallback onOpenSettings;

  const ReposScreen({super.key, required this.secretStore, required this.onOpenSettings});

  @override
  State<ReposScreen> createState() => _ReposScreenState();
}

/// What the long-press menu on a cloned repo can return.
enum _RepoAction { open, reclone, delete }

class _ReposScreenState extends State<ReposScreen> {
  final _filterController = TextEditingController();

  List<GithubRepo>? _repos;
  Set<String> _cloned = {};
  Directory? _reposRoot;

  /// Set when the account is missing entirely, which is a different screen
  /// from a network or API failure: one is a setup step, the other a retry.
  bool _noToken = false;
  String? _error;

  /// The repo currently being cloned, so its row can show progress and every
  /// other row stays inert while libgit2 works.
  String? _busyFullName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final reposRoot = await getApplicationDocumentsDirectory();
    try {
      final result = await loadReposWithCloneStatus(
        secretStore: widget.secretStore,
        reposRoot: reposRoot,
      );
      if (!mounted) return;
      setState(() {
        _repos = result.repos;
        _cloned = result.alreadyClonedFullNames;
        _reposRoot = reposRoot;
        _noToken = false;
        _error = null;
      });
    } on NoGithubTokenException {
      if (!mounted) return;
      setState(() {
        _repos = null;
        _noToken = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _repos = null;
        _noToken = false;
        _error = '$e';
      });
    }
  }

  /// The single reporting path for anything that fails. The token is stripped
  /// from the message before it can reach a widget, and GitHub's opaque
  /// 401/403 gets its explanation prepended.
  Future<void> _report(String title, Object failure) async {
    final token = await widget.secretStore.read(secretKeyGithubPat);
    final message = redactSecrets('$failure', token: token);
    final help = githubAuthHelp(message);
    if (!mounted) return;
    await showOutputPopup(
      context,
      title: title,
      body: help == null ? message : '$help\n\n$message',
    );
  }

  Future<Directory> _root() async {
    final root = _reposRoot ?? await getApplicationDocumentsDirectory();
    _reposRoot = root;
    return root;
  }

  void _openRepo(GithubRepo repo, Directory dir) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RepoScreen(repo: repo, repoDir: dir, secretStore: widget.secretStore),
    ));
  }

  Future<void> _clone(GithubRepo repo, {bool openAfter = true}) async {
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      await showOutputPopup(
        context,
        title: 'Not connected',
        body: 'Connect a GitHub account in Settings before cloning.',
      );
      return;
    }

    setState(() => _busyFullName = repo.fullName);
    Directory? cloned;
    Object? failure;
    try {
      cloned = await RepoGitService(reposRoot: await _root()).cloneRepo(repo: repo, token: token);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _busyFullName = null;
      if (cloned != null) _cloned = {..._cloned, repo.fullName};
    });

    if (failure != null) {
      await _report('Clone failed', failure);
      return;
    }
    if (openAfter && cloned != null) _openRepo(repo, cloned);
  }

  Future<void> _tapRepo(GithubRepo repo) async {
    if (_busyFullName != null) return;
    final dir = await repoDirectory(await _root(), repo.fullName);
    if (await dir.exists()) {
      if (!mounted) return;
      _openRepo(repo, dir);
      return;
    }
    if (!mounted) return;
    final confirmed = await showConfirmPopup(
      context,
      title: 'Clone ${repo.fullName}?',
      message: 'Downloads the whole repository into this app\'s storage on the device. '
          'You can delete the local copy again at any time.',
      detail: 'branch ${repo.defaultBranch}',
      confirmLabel: 'Clone',
    );
    if (!confirmed || !mounted) return;
    await _clone(repo);
  }

  /// The long-press / menu-button flow for a repo that is already on disk.
  Future<void> _manageClone(GithubRepo repo) async {
    if (_busyFullName != null) return;
    final action = await _showRepoActionsPopup(repo.fullName);
    if (action == null || !mounted) return;

    final dir = await repoDirectory(await _root(), repo.fullName);
    if (!mounted) return;

    switch (action) {
      case _RepoAction.open:
        _openRepo(repo, dir);

      case _RepoAction.delete:
        final ok = await showConfirmPopup(
          context,
          title: 'Delete local clone?',
          message: 'Any uncommitted local changes in this clone are lost for good. '
              'Nothing on GitHub is touched.',
          detail: repo.fullName,
          confirmLabel: 'Delete',
        );
        if (!ok || !mounted) return;
        await _deleteClone(repo, dir);

      case _RepoAction.reclone:
        final ok = await showConfirmPopup(
          context,
          title: 'Re-clone ${repo.fullName}?',
          message: 'The local copy is deleted and downloaded again from GitHub. '
              'Any uncommitted local changes are lost for good.',
          confirmLabel: 'Re-clone',
        );
        if (!ok || !mounted) return;
        if (await _deleteClone(repo, dir)) await _clone(repo, openAfter: false);
    }
  }

  /// Returns false when the delete failed, so a re-clone does not carry on
  /// over a directory that is still there.
  Future<bool> _deleteClone(GithubRepo repo, Directory dir) async {
    setState(() => _busyFullName = repo.fullName);
    Object? failure;
    try {
      await RepoGitService(reposRoot: await _root()).deleteLocalClone(dir);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return false;
    setState(() {
      _busyFullName = null;
      if (failure == null) _cloned = {..._cloned}..remove(repo.fullName);
    });
    if (failure != null) {
      await _report('Delete failed', failure);
      return false;
    }
    return true;
  }

  /// A three-way chooser. `showConfirmPopup` only carries a yes and a no, and
  /// mapping "re-clone" onto its Cancel button would make a stray tap outside
  /// the dialog destroy a working tree — so this one dialog is assembled from
  /// the same primitives, inside the same frame.
  Future<_RepoAction?> _showRepoActionsPopup(String fullName) {
    return showDialog<_RepoAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
        title: Text('Local clone', style: appHeading(size: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fullName, style: appMono(size: 12)),
            const SizedBox(height: 14),
            appSecondaryButton(label: 'Open', onPressed: () => Navigator.of(ctx).pop(_RepoAction.open)),
            const SizedBox(height: 8),
            appSecondaryButton(label: 'Re-clone', onPressed: () => Navigator.of(ctx).pop(_RepoAction.reclone)),
            const SizedBox(height: 8),
            appSecondaryButton(
              label: 'Delete local clone',
              onPressed: () => Navigator.of(ctx).pop(_RepoAction.delete),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Row(children: [
            Expanded(child: appPrimaryButton(label: 'Cancel', onPressed: () => Navigator.of(ctx).pop())),
          ]),
        ],
      ),
    );
  }

  List<GithubRepo> get _visibleRepos {
    final all = _repos ?? const <GithubRepo>[];
    final query = _filterController.text.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all.where((r) => r.fullName.toLowerCase().contains(query)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  Expanded(child: Text('Repositories', style: appHeading(size: 22))),
                  appIconCircleButton(icon: Icons.refresh, onPressed: _load),
                ],
              ),
            ),
            if (_repos != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: appBorderedField(
                  controller: _filterController,
                  hint: 'Filter repositories',
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_noToken) {
      return _CenteredState(
        icon: Icons.link_off,
        title: 'Connect your GitHub account',
        message: 'PocketGit needs a personal access token to list your repositories.',
        actionLabel: 'Open settings',
        onAction: widget.onOpenSettings,
      );
    }
    if (_error != null) {
      return _CenteredState(
        icon: Icons.error_outline,
        title: 'Could not load repositories',
        message: _error!,
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    if (_repos == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.fg));
    }

    final repos = _visibleRepos;
    return RefreshIndicator(
      color: AppColors.fg,
      backgroundColor: AppColors.bg,
      onRefresh: _load,
      child: repos.isEmpty
          // Still scrollable, or pull-to-refresh dies exactly when the list
          // the user wants to refresh is empty.
          ? ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
                  child: Text(
                    _repos!.isEmpty ? 'This account has no repositories.' : 'No repository matches that filter.',
                    style: appBody(color: AppColors.muted),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            )
          : ListView.builder(
              itemCount: repos.length,
              itemBuilder: (_, i) {
                final repo = repos[i];
                final isCloned = _cloned.contains(repo.fullName);
                return _RepoRow(
                  repo: repo,
                  isCloned: isCloned,
                  isBusy: _busyFullName == repo.fullName,
                  locked: _busyFullName != null,
                  onTap: () => _tapRepo(repo),
                  onManage: isCloned ? () => _manageClone(repo) : null,
                );
              },
            ),
    );
  }
}

class _RepoRow extends StatelessWidget {
  final GithubRepo repo;
  final bool isCloned;
  final bool isBusy;
  final bool locked;
  final VoidCallback onTap;
  final VoidCallback? onManage;

  const _RepoRow({
    required this.repo,
    required this.isCloned,
    required this.isBusy,
    required this.locked,
    required this.onTap,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: locked ? null : onTap,
      onLongPress: locked ? null : onManage,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider, width: 2)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: isBusy
                  ? const Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.fg, width: 2),
                        borderRadius: BorderRadius.circular(10),
                        color: isCloned ? AppColors.fg : AppColors.bg,
                      ),
                      child: Icon(
                        isCloned ? Icons.folder_open : Icons.cloud_download_outlined,
                        size: 16,
                        color: isCloned ? AppColors.bg : AppColors.fg,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(repo.fullName, style: appMono(size: 13.5), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text(
                    isBusy
                        ? 'working…'
                        : '${isCloned ? 'cloned' : 'not cloned'}  ·  ${repo.defaultBranch}',
                    style: appBody(size: 11, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            if (onManage != null) ...[
              const SizedBox(width: 8),
              appIconCircleButton(icon: Icons.more_horiz, onPressed: locked ? null : onManage),
            ],
          ],
        ),
      ),
    );
  }
}

/// The empty, error and not-connected screens; all three are one line of text
/// and one button.
class _CenteredState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _CenteredState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: AppColors.fg),
            const SizedBox(height: 16),
            Text(title, style: appHeading(size: 17), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(message, style: appBody(size: 12.5, color: AppColors.muted), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            appSecondaryButton(label: actionLabel, onPressed: onAction),
          ],
        ),
      ),
    );
  }
}
