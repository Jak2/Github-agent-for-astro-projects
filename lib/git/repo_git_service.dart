// lib/git/repo_git_service.dart
import 'dart:io';

import 'package:git2dart/git2dart.dart';

import '../github/github_repo.dart';
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

    final repository = Repository.clone(
      url: repo.cloneUrl,
      localPath: dir.path,
      checkoutBranch: repo.defaultBranch,
      callbacks: _tokenCallbacks(token),
    );
    repository.free();

    return dir;
  }

  Future<void> commitAndPush({
    required Directory repoDir,
    required String relativeFilePath,
    required String content,
    required String commitMessage,
    required String token,
  }) async {
    // ponytail: no rollback on partial failure (file written/committed but push fails) —
    // repo is left dirty locally, next run's write+commit will just create a new commit
    // on top; add cleanup if this proves confusing in practice.
    final repository = Repository.open(repoDir.path);
    try {
      final file = File('${repoDir.path}/$relativeFilePath');
      await file.create(recursive: true);
      await file.writeAsString(content);

      final author = Signature.create(
        name: 'git_agent_app',
        email: 'git_agent_app@users.noreply.github.com',
      );

      repository.createCommitOnHead(
        [relativeFilePath],
        author,
        author,
        commitMessage,
      );

      final remote = Remote.lookup(repo: repository, name: 'origin');
      try {
        final branch = repository.head.shorthand;
        remote.push(
          refspecs: ['refs/heads/$branch:refs/heads/$branch'],
          callbacks: _tokenCallbacks(token),
        );
      } finally {
        remote.free();
      }
    } finally {
      repository.free();
    }
  }

  // ---------------------------------------------------------------------
  // Chip actions. Deterministic git, driven from buttons — none of this
  // goes anywhere near a prompt.
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

      final author = Signature.create(
        name: 'git_agent_app',
        email: 'git_agent_app@users.noreply.github.com',
      );
      final oid = Commit.create(
        repo: repository,
        updateRef: 'HEAD',
        author: author,
        committer: author,
        message: message,
        tree: Tree.lookup(repo: repository, oid: treeOid),
        parents: [repository.headCommit],
      );

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
      // A forced checkout onto a dirty tree silently eats local edits.
      final dirty = repository.status;
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
