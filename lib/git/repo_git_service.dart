// lib/git/repo_git_service.dart
import 'dart:io';

import 'package:git2dart/git2dart.dart';

import '../github/github_repo.dart';
import 'git_identity.dart';
import 'repo_paths.dart';

/// Clones/commits/pushes a [GithubRepo] using git2dart (real libgit2 FFI
/// bindings) over HTTPS with a personal access token.
class RepoGitService {
  final Directory reposRoot;

  RepoGitService({required this.reposRoot});

  Callbacks _tokenCallbacks(String token) {
    // GitHub accepts the PAT as the password with any non-empty username.
    return Callbacks(credentials: UserPass(username: token, password: token));
  }

  Future<Directory> cloneRepo({
    required GithubRepo repo,
    required String token,
  }) async {
    final dir = await repoDirectory(reposRoot, repo.fullName);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    try {
      // ponytail: libgit2 is synchronous FFI on the main isolate — a large
      // clone blocks the UI thread and can ANR. Moving it to an isolate means
      // re-opening the repo there (git2dart handles do not travel); do that if
      // real repos prove slow enough to matter.
      final repository = Repository.clone(
        url: repo.cloneUrl,
        localPath: dir.path,
        checkoutBranch: repo.defaultBranch,
        callbacks: _tokenCallbacks(token),
      );
      repository.free();
    } catch (_) {
      // A half-written directory still passes the exists() check the repo list
      // uses to decide what is cloned, so a failed clone would show as cloned
      // forever and never open.
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }

    return dir;
  }

  Signature _signature(CommitIdentity identity) =>
      Signature.create(name: identity.name, email: identity.email);

  /// Pushes the checked-out branch to origin and returns its name.
  ///
  /// The token only ever reaches libgit2 through [_tokenCallbacks]; nothing
  /// here puts it in a string.
  String _pushHead(Repository repository, String token) {
    final branch = repository.head.shorthand;
    final remote = Remote.lookup(repo: repository, name: 'origin');
    try {
      remote.push(
        refspecs: ['refs/heads/$branch:refs/heads/$branch'],
        callbacks: _tokenCallbacks(token),
      );
    } finally {
      remote.free();
    }
    return branch;
  }

  /// Pushes the current branch without committing anything.
  ///
  /// The retry path: the commit landed locally and only the push failed, so
  /// re-committing would be wrong.
  Future<String> pushCurrentBranch({
    required Directory repoDir,
    required String token,
  }) async {
    final repository = Repository.open(repoDir.path);
    try {
      final branch = _pushHead(repository, token);
      return 'Pushed $branch to origin.';
    } finally {
      repository.free();
    }
  }

  // ---------------------------------------------------------------------
  // Read-only inspection. Every one of these backs a button in the repo
  // screen and renders into a popup.
  // ---------------------------------------------------------------------

  /// `git status --short`, already formatted for display.
  ///
  /// Never empty: a clean tree says so out loud.
  Future<List<String>> statusLines(Directory repoDir) async {
    final repository = Repository.open(repoDir.path);
    try {
      return formatStatusLines(_fullStatus(repository));
    } finally {
      repository.free();
    }
  }

  /// Every uncommitted path — modified, added, deleted, untracked — sorted.
  ///
  /// The same merged view [statusLines] renders, minus the formatting: the
  /// uncommitted-changes bar wants the paths themselves.
  Future<List<String>> uncommittedPaths(Directory repoDir) async {
    final repository = Repository.open(repoDir.path);
    try {
      return _fullStatus(repository).keys.toList()..sort();
    } finally {
      repository.free();
    }
  }

  /// `repository.status` runs libgit2 with default options, which omit
  /// untracked files entirely — a Status button blind to a new file is worse
  /// than no button, so the untracked half comes from an index-to-workdir
  /// diff and is merged in.
  Map<String, Set<GitStatus>> _fullStatus(Repository repository) {
    final result = Map<String, Set<GitStatus>>.from(repository.status);
    final diff = Diff.indexToWorkdir(
      repo: repository,
      index: repository.index,
      flags: const {GitDiff.includeUntracked, GitDiff.recurseUntrackedDirs},
    );
    for (final delta in diff.deltas) {
      if (delta.status == GitDelta.untracked) {
        result.putIfAbsent(delta.newFile.path, () => {GitStatus.wtNew});
      }
    }
    return result;
  }

  /// The most recent [limit] commits, newest first. Empty on an unborn HEAD.
  Future<List<GitCommitInfo>> recentCommits(
    Directory repoDir, {
    int limit = 10,
  }) async {
    final repository = Repository.open(repoDir.path);
    try {
      // A repo with no commits has an unborn HEAD; asking for the log throws.
      if (repository.isEmpty) return const [];
      final commits = repository.log(oid: repository.head.target).take(limit);
      return [
        for (final c in commits)
          GitCommitInfo(
            sha: c.oid.sha,
            message: c.message,
            author: c.author.name,
            when: DateTime.fromMillisecondsSinceEpoch(c.time * 1000),
          ),
      ];
    } finally {
      repository.free();
    }
  }

  /// Local branches, the checked-out one marked with `*`.
  Future<List<String>> branchLines(Directory repoDir) async {
    final repository = Repository.open(repoDir.path);
    try {
      final branches = repository.branchesLocal;
      final names = <String>[];
      for (final b in branches) {
        names.add('${b.isHead ? '* ' : '  '}${b.name}');
        b.free();
      }
      names.sort((a, b) {
        // Current branch first, then alphabetical.
        if (a.startsWith('*') != b.startsWith('*')) {
          return a.startsWith('*') ? -1 : 1;
        }
        return a.substring(2).compareTo(b.substring(2));
      });
      return names.isEmpty ? const ['(no local branches)'] : names;
    } finally {
      repository.free();
    }
  }

  /// Stages every pending change (`git add -A`), commits it and pushes the
  /// current branch. Returns a one-line summary.
  ///
  /// Throws [StateError] with a plain message when there is nothing to commit.
  Future<String> commitAllAndPush({
    required Directory repoDir,
    required String message,
    required String token,
    required CommitIdentity identity,
  }) async {
    final repository = Repository.open(repoDir.path);
    try {
      final pending = _fullStatus(repository);
      if (pending.isEmpty) {
        throw StateError('Nothing to commit — working tree clean.');
      }

      final index = repository.index;
      index.addAll(['*']); // new + modified
      index.updateAll(['*']); // picks up deletions
      index.write();
      final treeOid = index.writeTree();

      final author = _signature(identity);
      final oid = Commit.create(
        repo: repository,
        updateRef: 'HEAD',
        author: author,
        committer: author,
        message: message,
        tree: Tree.lookup(repo: repository, oid: treeOid),
        // An unborn HEAD (freshly cloned empty repo) has no parent to point at.
        parents: repository.isEmpty ? const [] : [repository.headCommit],
      );

      final branch = _pushHead(repository, token);

      return 'Committed ${pending.length} path(s) as ${shortSha(oid.sha)} '
          'and pushed to origin/$branch.';
    } finally {
      repository.free();
    }
  }

  /// Fetches origin and fast-forwards the current branch. Never merges.
  ///
  /// Throws [StateError] with a plain, user-facing message when a
  /// fast-forward is not possible — the caller shows it verbatim.
  Future<String> pullFastForward({
    required Directory repoDir,
    required String token,
  }) async {
    final repository = Repository.open(repoDir.path);
    try {
      // A forced checkout onto a dirty tree silently eats local edits — and
      // an untracked file the remote also adds is overwritten just as
      // quietly, so the guard uses the merged status, not libgit2's default.
      final dirty = _fullStatus(repository);
      if (dirty.isNotEmpty) {
        throw StateError(
          'Working tree has ${dirty.length} uncommitted change(s) — '
          'commit or discard them before pulling.',
        );
      }

      final branch = repository.head.shorthand;
      final remote = Remote.lookup(repo: repository, name: 'origin');
      try {
        remote.fetch(callbacks: _tokenCallbacks(token));
      } finally {
        remote.free();
      }

      final remoteRefName = 'refs/remotes/origin/$branch';
      if (!repository.references.contains(remoteRefName)) {
        throw StateError('No origin/$branch on the remote — nothing to pull.');
      }
      final target =
          Reference.lookup(repo: repository, name: remoteRefName).target;
      final analysis = Merge.analysis(repo: repository, theirHead: target);
      if (analysis.result.contains(GitMergeAnalysis.upToDate)) {
        return '$branch is already up to date with origin/$branch.';
      }
      if (!analysis.result.contains(GitMergeAnalysis.fastForward)) {
        throw StateError(
          'Fast-forward not possible: $branch and origin/$branch have '
          'diverged. Not attempting a merge — resolve this with a full git '
          'client.',
        );
      }

      Reference.setTarget(
        repo: repository,
        name: 'refs/heads/$branch',
        target: target,
        logMessage: 'pull: fast-forward',
      );
      Checkout.head(repo: repository, strategy: const {GitCheckout.force});

      return 'Fast-forwarded $branch to ${shortSha(target.sha)}.';
    } finally {
      repository.free();
    }
  }

  /// Stages only [relativePaths], commits them and pushes.
  ///
  /// The selective half of commit & push: anything not named stays pending.
  ///
  /// Throws [StateError] when nothing was selected, or when none of the
  /// selected paths actually have pending changes — committing an empty tree
  /// delta is a confusing no-op, not a success.
  Future<String> commitFilesAndPush({
    required Directory repoDir,
    required List<String> relativePaths,
    required String message,
    required String token,
    required CommitIdentity identity,
  }) async {
    if (relativePaths.isEmpty) {
      throw StateError('No files selected — nothing to commit.');
    }
    final repository = Repository.open(repoDir.path);
    try {
      final pending = _fullStatus(repository);
      final selected =
          relativePaths.where(pending.containsKey).toList()..sort();
      if (selected.isEmpty) {
        throw StateError(
          'None of the selected files have pending changes.',
        );
      }

      final index = repository.index;
      for (final path in selected) {
        // A path that is pending but gone from disk was deleted: staging it
        // means removing it from the index, not adding it.
        if (File('${repoDir.path}/$path').existsSync()) {
          index.add(path);
        } else {
          index.remove(path);
        }
      }
      index.write();

      final author = _signature(identity);
      final oid = Commit.create(
        repo: repository,
        updateRef: 'HEAD',
        author: author,
        committer: author,
        message: message,
        tree: Tree.lookup(repo: repository, oid: index.writeTree()),
        // An unborn HEAD (freshly cloned empty repo) has no parent to point at.
        parents: repository.isEmpty ? const [] : [repository.headCommit],
      );

      final branch = _pushHead(repository, token);

      return 'Committed ${selected.length} path(s) as ${shortSha(oid.sha)} '
          'and pushed to origin/$branch.';
    } finally {
      repository.free();
    }
  }

  /// The checked-out branch.
  Future<String> currentBranchName(Directory repoDir) async {
    final repository = Repository.open(repoDir.path);
    try {
      if (repository.isBranchUnborn) {
        // libgit2 refuses to resolve an unborn HEAD, but the file still names
        // the branch the first commit will land on.
        final head = File('${repository.path}HEAD').readAsStringSync().trim();
        const prefix = 'ref: refs/heads/';
        return head.startsWith(prefix) ? head.substring(prefix.length) : 'HEAD';
      }
      return repository.head.shorthand;
    } finally {
      repository.free();
    }
  }

  /// Creates a branch at the current commit, and switches to it by default.
  ///
  /// The switch only moves HEAD: the new branch points at the commit already
  /// checked out, so the working tree is already correct and uncommitted work
  /// carries over — exactly like `git checkout -b`.
  ///
  /// Throws [StateError] on an invalid or already-used name.
  Future<String> createBranch({
    required Directory repoDir,
    required String name,
    bool checkout = true,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || !Branch.isNameValid(trimmed)) {
      throw StateError('"$name" is not a valid branch name.');
    }
    final repository = Repository.open(repoDir.path);
    try {
      if (repository.isEmpty) {
        throw StateError('This repository has no commits to branch from.');
      }
      if (repository.references.contains('refs/heads/$trimmed')) {
        throw StateError('Branch "$trimmed" already exists.');
      }

      Branch.create(
        repo: repository,
        name: trimmed,
        target: repository.headCommit,
      ).free();

      if (checkout) {
        repository.setHead('refs/heads/$trimmed');
        return 'Created $trimmed and switched to it.';
      }
      return 'Created $trimmed.';
    } finally {
      repository.free();
    }
  }

  /// Switches to an existing local branch.
  ///
  /// Throws [StateError] when the tree is dirty: switching branches for real
  /// rewrites the working tree, and a forced checkout eats uncommitted work.
  Future<String> checkoutBranch({
    required Directory repoDir,
    required String name,
  }) async {
    final repository = Repository.open(repoDir.path);
    try {
      final refName = 'refs/heads/$name';
      if (!repository.references.contains(refName)) {
        throw StateError('No local branch named "$name".');
      }
      if (repository.head.shorthand == name) {
        return 'Already on $name.';
      }
      final dirty = _fullStatus(repository);
      if (dirty.isNotEmpty) {
        throw StateError(
          'Working tree has ${dirty.length} uncommitted change(s) — '
          'commit or discard them before switching branches.',
        );
      }

      Checkout.reference(repo: repository, name: refName);
      repository.setHead(refName);
      return 'Switched to $name.';
    } finally {
      repository.free();
    }
  }

  /// Throws away the pending change to one path.
  ///
  /// An untracked file has no committed version to go back to, so the only
  /// way to discard it is to delete it; anything tracked is restored from
  /// HEAD, which also unstages it.
  Future<void> discardChanges({
    required Directory repoDir,
    required String relativePath,
  }) async {
    final repository = Repository.open(repoDir.path);
    try {
      final flags = _fullStatus(repository)[relativePath];
      if (flags == null) return; // nothing pending for this path

      if (flags.contains(GitStatus.wtNew) &&
          !flags.contains(GitStatus.indexNew)) {
        final file = File('${repoDir.path}/$relativePath');
        if (file.existsSync()) file.deleteSync();
        return;
      }

      if (flags.contains(GitStatus.indexNew)) {
        // Staged but never committed: HEAD has nothing to restore, so drop the
        // index entry and the file with it.
        final index = repository.index;
        index.remove(relativePath);
        index.write();
        final file = File('${repoDir.path}/$relativePath');
        if (file.existsSync()) file.deleteSync();
        return;
      }

      Checkout.head(
        repo: repository,
        strategy: const {GitCheckout.force},
        paths: [relativePath],
      );
    } finally {
      repository.free();
    }
  }

  /// The working tree as a unified patch against HEAD (index included), so
  /// the user can read exactly what a commit would contain.
  ///
  /// Pass [relativePath] for a single file. Never empty: no diff says so.
  Future<List<String>> diffLines(
    Directory repoDir, {
    String? relativePath,
  }) async {
    final repository = Repository.open(repoDir.path);
    try {
      final diff = Diff.treeToWorkdirWithIndex(
        repo: repository,
        tree: repository.isEmpty ? null : repository.headCommit.tree,
        flags: const {
          GitDiff.includeUntracked,
          GitDiff.recurseUntrackedDirs,
          GitDiff.showUntrackedContent,
        },
      );

      final String text;
      if (relativePath == null) {
        text = diff.patch;
      } else {
        // libgit2's diff options take no pathspec through git2dart, so the
        // single-file view filters the patches it produced.
        final buffer = StringBuffer();
        for (final patch in diff.patches) {
          final delta = patch.delta;
          if (delta.newFile.path == relativePath ||
              delta.oldFile.path == relativePath) {
            buffer.write(patch.text);
          }
          patch.free();
        }
        text = buffer.toString();
      }
      diff.free();

      final lines = text.split('\n');
      while (lines.isNotEmpty && lines.last.isEmpty) {
        lines.removeLast();
      }
      return lines.isEmpty ? const ['no changes'] : lines;
    } finally {
      repository.free();
    }
  }

  /// Deletes the local clone. The remote is untouched.
  Future<void> deleteLocalClone(Directory repoDir) async {
    if (await repoDir.exists()) {
      await repoDir.delete(recursive: true);
    }
  }
}

/// A commit flattened off the FFI objects, so formatting is testable without
/// libgit2 in the loop.
class GitCommitInfo {
  final String sha;
  final String message;
  final String author;
  final DateTime when;

  const GitCommitInfo({
    required this.sha,
    required this.message,
    required this.author,
    required this.when,
  });
}

String shortSha(String sha) => sha.length <= 7 ? sha : sha.substring(0, 7);

/// One `XY path` line per changed path, in `git status --short` shape.
///
/// A clean tree returns a single explicit line rather than nothing at all —
/// an empty result renders as an empty bubble and reads as a broken button.
List<String> formatStatusLines(Map<String, Set<GitStatus>> status) {
  if (status.isEmpty) return const ['working tree clean'];

  final paths = status.keys.toList()..sort();
  return [
    for (final path in paths) '${statusCode(status[path]!)}  $path',
  ];
}

/// The two-column `XY` code: staged column, then working-tree column.
String statusCode(Set<GitStatus> flags) {
  if (flags.contains(GitStatus.conflicted)) return 'UU';
  if (flags.contains(GitStatus.ignored)) return '!!';
  if (flags.contains(GitStatus.wtNew) &&
      !flags.contains(GitStatus.indexNew) &&
      !flags.contains(GitStatus.indexModified) &&
      !flags.contains(GitStatus.indexRenamed) &&
      !flags.contains(GitStatus.indexTypeChange)) {
    return '??';
  }

  final index = switch (flags) {
    _ when flags.contains(GitStatus.indexNew) => 'A',
    _ when flags.contains(GitStatus.indexModified) => 'M',
    _ when flags.contains(GitStatus.indexDeleted) => 'D',
    _ when flags.contains(GitStatus.indexRenamed) => 'R',
    _ when flags.contains(GitStatus.indexTypeChange) => 'T',
    _ => ' ',
  };
  final worktree = switch (flags) {
    _ when flags.contains(GitStatus.wtDeleted) => 'D',
    _ when flags.contains(GitStatus.wtModified) => 'M',
    _ when flags.contains(GitStatus.wtRenamed) => 'R',
    _ when flags.contains(GitStatus.wtTypeChange) => 'T',
    _ when flags.contains(GitStatus.wtNew) => 'A',
    _ when flags.contains(GitStatus.wtUnreadable) => 'X',
    _ => ' ',
  };
  return '$index$worktree';
}

/// `abc1234  first line of message  — author, 3 days ago`
List<String> formatLogLines(List<GitCommitInfo> commits, {DateTime? now}) {
  if (commits.isEmpty) return const ['no commits yet'];
  final at = now ?? DateTime.now();
  return [
    for (final c in commits)
      '${shortSha(c.sha)}  ${firstLine(c.message)}\n'
          '         ${c.author}, ${relativeDate(c.when, now: at)}',
  ];
}

String firstLine(String message) {
  final line = message.split('\n').first.trim();
  return line.length <= 72 ? line : '${line.substring(0, 71)}…';
}

String relativeDate(DateTime when, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(when);
  if (d.isNegative) return 'just now';
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  if (d.inDays < 365) return '${d.inDays ~/ 30}mo ago';
  return '${d.inDays ~/ 365}y ago';
}

/// Caps a 200-file status at something a chat bubble can hold, and says how
/// much was left out instead of silently dropping it.
List<String> truncateLines(List<String> lines, {int max = 40}) {
  if (lines.length <= max) return lines;
  return [...lines.take(max), '…and ${lines.length - max} more'];
}

final _urlCredentials = RegExp(r'(https?://)[^/@\s]+@');

/// Strips anything that could carry the PAT out of a message before it is
/// rendered. Applied to every git error the UI shows.
String redactSecrets(String message, {String? token}) {
  var out = message.replaceAllMapped(_urlCredentials, (m) => '${m[1]}***@');
  if (token != null && token.isNotEmpty) {
    out = out.replaceAll(token, '***');
  }
  return out;
}

/// libgit2 reports a refused push as `unexpected http status code: 403`, which
/// tells the user nothing they can act on. 401/403 from GitHub over HTTPS is
/// almost never a bug in this app — it is the token — so name the four causes
/// and the fix. Returns null for anything that is not an HTTP auth failure;
/// the caller still shows the raw error either way.
String? githubAuthHelp(String message) {
  final match = RegExp(r'http.*?\b(401|403)\b', caseSensitive: false, dotAll: true)
      .firstMatch(message);
  if (match == null) return null;
  final code = match.group(1)!;
  final refused = code == '401'
      ? 'GitHub rejected the token (HTTP 401) — it is invalid, revoked, or expired.'
      : 'GitHub accepted the token but refused the write (HTTP 403).';
  return '$refused\nLikely causes:\n'
      '  - a classic PAT without the "repo" scope\n'
      '  - a fine-grained PAT without Contents: Read and write on this repository\n'
      '  - the token has expired\n'
      '  - the account has no push access to this repository\n'
      'Tap "Check access" to see which one it is.';
}
