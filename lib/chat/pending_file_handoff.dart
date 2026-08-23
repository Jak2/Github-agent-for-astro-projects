import 'dart:io';
import '../github/github_repo.dart';

typedef PendingFile = ({GithubRepo repo, Directory repoDir, String relativePath, String content});

/// App-wide holder for a "please open this file in the structuring chat"
/// request. General Chat's "Structure this file" action calls [request],
/// then asks the root screen to switch to the GitHub tab; that tab calls
/// [consume] when it becomes visible again to pick up the request.
class PendingFileHandoff {
  PendingFileHandoff._();
  static final PendingFileHandoff instance = PendingFileHandoff._();

  PendingFile? _pending;

  void request({
    required GithubRepo repo,
    required Directory repoDir,
    required String relativePath,
    required String content,
  }) {
    _pending = (repo: repo, repoDir: repoDir, relativePath: relativePath, content: content);
  }

  /// Returns the pending request and clears it, or null if there isn't one.
  PendingFile? consume() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}
