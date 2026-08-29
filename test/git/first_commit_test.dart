// test/git/first_commit_test.dart
//
// The first commit into a freshly cloned *empty* repository has no parent.
// libgit2 throws when asked to resolve an unborn HEAD, so this is the one
// commit path that cannot look up `headCommit` — and the one a new user hits
// first, having just made a repo on GitHub with no README.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart';
import 'package:pocket_git/git/git_identity.dart';
import 'package:pocket_git/git/repo_git_service.dart';

void main() {
  late Directory bare;
  late Directory work;
  late RepoGitService service;

  const identity = CommitIdentity(name: 'Tester', email: 'tester@example.com');

  setUp(() {
    bare = Directory.systemTemp.createTempSync('pocket_git_empty_bare');
    work = Directory.systemTemp.createTempSync('pocket_git_empty_work');
    Repository.init(path: bare.path, bare: true).free();
    Repository.init(path: work.path).free();
    final repo = Repository.open(work.path);
    Remote.create(repo: repo, name: 'origin', url: bare.path).free();
    repo.free();
    service = RepoGitService(reposRoot: work);
  });

  tearDown(() {
    bare.deleteSync(recursive: true);
    work.deleteSync(recursive: true);
  });

  test('commit & push works on a repository with no commits at all', () async {
    File('${work.path}/README.md').writeAsStringSync('# new repo\n');

    final summary = await service.commitAllAndPush(
      repoDir: work,
      message: 'first commit',
      token: '',
      identity: identity,
    );

    expect(summary, contains('pushed to origin/'));
    expect(await service.statusLines(work), ['working tree clean']);

    final log = await service.recentCommits(work);
    expect(log.single.message.trim(), 'first commit');
    expect(log.single.author, 'Tester');

    final remote = Repository.open(bare.path);
    expect(remote.head.target.sha, log.single.sha);
    remote.free();
  });

  test('committing one named file into an empty repository leaves the rest alone', () async {
    File('${work.path}/keep.md').writeAsStringSync('committed\n');
    File('${work.path}/later.md').writeAsStringSync('not yet\n');

    await service.commitFilesAndPush(
      repoDir: work,
      relativePaths: const ['keep.md'],
      message: 'just the one',
      token: '',
      identity: identity,
    );

    expect(await service.uncommittedPaths(work), ['later.md']);
  });
}
