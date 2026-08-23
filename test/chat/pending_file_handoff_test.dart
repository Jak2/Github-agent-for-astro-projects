import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/pending_file_handoff.dart';
import 'package:git_agent_app/github/github_repo.dart';

void main() {
  setUp(() {
    // Drain any leftover state from a previous test before each run,
    // since PendingFileHandoff.instance is a process-wide singleton.
    PendingFileHandoff.instance.consume();
  });

  test('consume returns null when nothing was requested', () {
    expect(PendingFileHandoff.instance.consume(), isNull);
  });

  test('consume returns the requested file exactly once', () {
    const repo = GithubRepo(fullName: 'jak2/repo', cloneUrl: 'https://x', defaultBranch: 'main');
    final dir = Directory('/tmp/repo');
    PendingFileHandoff.instance.request(
      repo: repo,
      repoDir: dir,
      relativePath: 'notes/idea.txt',
      content: 'raw notes',
    );

    final first = PendingFileHandoff.instance.consume();
    expect(first, isNotNull);
    expect(first!.repo.fullName, 'jak2/repo');
    expect(first.repoDir.path, '/tmp/repo');
    expect(first.relativePath, 'notes/idea.txt');
    expect(first.content, 'raw notes');

    expect(PendingFileHandoff.instance.consume(), isNull);
  });

  test('a second request overwrites an unconsumed first one', () {
    const repoA = GithubRepo(fullName: 'jak2/a', cloneUrl: 'https://a', defaultBranch: 'main');
    const repoB = GithubRepo(fullName: 'jak2/b', cloneUrl: 'https://b', defaultBranch: 'main');
    PendingFileHandoff.instance.request(
      repo: repoA,
      repoDir: Directory('/tmp/a'),
      relativePath: 'a.txt',
      content: 'a',
    );
    PendingFileHandoff.instance.request(
      repo: repoB,
      repoDir: Directory('/tmp/b'),
      relativePath: 'b.txt',
      content: 'b',
    );

    final result = PendingFileHandoff.instance.consume();
    expect(result!.repo.fullName, 'jak2/b');
  });
}
