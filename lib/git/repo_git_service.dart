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
}
