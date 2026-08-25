// test/git/repo_git_service_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart';
import 'package:git_agent_app/git/repo_git_service.dart';

void main() {
  group('formatStatusLines', () {
    test('a clean tree says so instead of rendering nothing', () {
      expect(formatStatusLines({}), ['working tree clean']);
    });

    test('untracked, modified and staged files get git-shaped codes', () {
      final lines = formatStatusLines({
        'new.txt': {GitStatus.wtNew},
        'edited.dart': {GitStatus.wtModified},
        'staged.dart': {GitStatus.indexNew},
        'gone.dart': {GitStatus.wtDeleted},
      });
      expect(lines, [
        ' M  edited.dart',
        ' D  gone.dart',
        '??  new.txt',
        'A   staged.dart',
      ]);
    });

    test('a file staged and then edited again shows both columns', () {
      expect(
        statusCode({GitStatus.indexModified, GitStatus.wtModified}),
        'MM',
      );
    });

    test('conflicts outrank every other flag', () {
      expect(
        statusCode({GitStatus.conflicted, GitStatus.wtModified}),
        'UU',
      );
    });

    test('paths are sorted so the same status renders identically twice', () {
      final lines = formatStatusLines({
        'z.dart': {GitStatus.wtModified},
        'a.dart': {GitStatus.wtModified},
      });
      expect(lines.first, contains('a.dart'));
    });
  });

  group('formatLogLines', () {
    final now = DateTime(2026, 8, 25, 12);

    test('renders short sha, subject, author and a relative date', () {
      final lines = formatLogLines([
        GitCommitInfo(
          sha: '0123456789abcdef',
          message: 'fix: stop the thing\n\nlong body ignored',
          author: 'jak2',
          when: now.subtract(const Duration(days: 3)),
        ),
      ], now: now);
      expect(lines.single, contains('0123456'));
      expect(lines.single, contains('fix: stop the thing'));
      expect(lines.single, isNot(contains('long body')));
      expect(lines.single, contains('jak2, 3d ago'));
    });

    test('an empty history says so rather than rendering nothing', () {
      expect(formatLogLines(const []), ['no commits yet']);
    });

    test('an over-long subject is ellipsised, not wrapped forever', () {
      final subject = 'x' * 200;
      final line = firstLine(subject);
      expect(line.length, 72);
      expect(line, endsWith('…'));
    });
  });

  group('relativeDate', () {
    final now = DateTime(2026, 8, 25, 12);

    test('buckets each magnitude', () {
      expect(relativeDate(now.subtract(const Duration(seconds: 5)), now: now), 'just now');
      expect(relativeDate(now.subtract(const Duration(minutes: 5)), now: now), '5m ago');
      expect(relativeDate(now.subtract(const Duration(hours: 5)), now: now), '5h ago');
      expect(relativeDate(now.subtract(const Duration(days: 5)), now: now), '5d ago');
      expect(relativeDate(now.subtract(const Duration(days: 90)), now: now), '3mo ago');
      expect(relativeDate(now.subtract(const Duration(days: 800)), now: now), '2y ago');
    });

    test('a commit dated in the future does not render a negative age', () {
      expect(relativeDate(now.add(const Duration(days: 2)), now: now), 'just now');
    });
  });

  group('truncateLines', () {
    test('leaves a short list alone', () {
      expect(truncateLines(['a', 'b'], max: 40), ['a', 'b']);
    });

    test('a 200-file status is capped and says how much was dropped', () {
      final lines = List.generate(200, (i) => 'file$i');
      final out = truncateLines(lines, max: 40);
      expect(out.length, 41);
      expect(out.last, '…and 160 more');
    });

    test('exactly at the cap is not truncated', () {
      final lines = List.generate(40, (i) => 'file$i');
      expect(truncateLines(lines, max: 40).length, 40);
    });
  });

  group('redactSecrets', () {
    test('replaces the token wherever it appears', () {
      final out = redactSecrets(
        'failed to push to https://github.com/a/b: bad credentials ghp_SECRET',
        token: 'ghp_SECRET',
      );
      expect(out, isNot(contains('ghp_SECRET')));
      expect(out, contains('***'));
    });

    test('strips credentials embedded in a remote url even without the token', () {
      final out = redactSecrets(
        'remote https://ghp_SECRET@github.com/a/b.git rejected',
      );
      expect(out, isNot(contains('ghp_SECRET')));
      expect(out, contains('https://***@github.com/a/b.git'));
    });

    test('user:password form is stripped too', () {
      final out = redactSecrets('https://user:ghp_SECRET@github.com/a/b.git');
      expect(out, isNot(contains('ghp_SECRET')));
      expect(out, isNot(contains('user:')));
    });

    test('an empty token does not blank the whole message', () {
      expect(redactSecrets('boom', token: ''), 'boom');
    });
  });

  // Real libgit2 against a throwaway repo on disk. No network: init, commit,
  // read back. If these pass, the read-only chips are exercised end to end.
  group('against a real repository', () {
    late Directory tmp;
    late RepoGitService service;

    Signature sig() => Signature.create(
          name: 'test',
          email: 'test@example.com',
          time: 1756000000,
        );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('git_agent_app_test');
      Repository.init(path: tmp.path).free();
      service = RepoGitService(reposRoot: tmp);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void commit(String path, String content, String message) {
      File('${tmp.path}/$path').writeAsStringSync(content);
      final repo = Repository.open(tmp.path);
      final index = repo.index;
      index.add(path);
      index.write();
      final tree = Tree.lookup(repo: repo, oid: index.writeTree());
      Commit.create(
        repo: repo,
        updateRef: 'HEAD',
        author: sig(),
        committer: sig(),
        message: message,
        tree: tree,
        parents: repo.isEmpty ? [] : [repo.headCommit],
      );
      repo.free();
    }

    test('a fresh repo has no log rather than throwing on an unborn HEAD', () async {
      expect(await service.recentCommits(tmp), isEmpty);
      expect(formatLogLines(await service.recentCommits(tmp)), ['no commits yet']);
    });

    test('status reports untracked, then clean after a commit', () async {
      File('${tmp.path}/a.txt').writeAsStringSync('hello');
      expect(await service.statusLines(tmp), ['??  a.txt']);

      commit('a.txt', 'hello', 'first');
      expect(await service.statusLines(tmp), ['working tree clean']);

      File('${tmp.path}/a.txt').writeAsStringSync('changed');
      expect(await service.statusLines(tmp), [' M  a.txt']);
    });

    test('log returns newest first and is capped at the limit', () async {
      commit('a.txt', '1', 'first');
      commit('a.txt', '2', 'second');
      commit('a.txt', '3', 'third');

      final all = await service.recentCommits(tmp);
      expect(all.map((c) => c.message.trim()), ['third', 'second', 'first']);
      expect(all.first.author, 'test');
      expect(all.first.sha.length, 40);

      expect((await service.recentCommits(tmp, limit: 2)).length, 2);
    });

    test('branches marks the checked-out one', () async {
      commit('a.txt', '1', 'first');
      final repo = Repository.open(tmp.path);
      Branch.create(repo: repo, name: 'side', target: repo.headCommit);
      repo.free();

      final lines = await service.branchLines(tmp);
      expect(lines.first, startsWith('* '));
      expect(lines.map((l) => l.substring(2)), containsAll(['side']));
    });

    test('commit & push refuses a clean tree before it ever reaches the network', () async {
      commit('a.txt', '1', 'first');
      expect(
        () => service.commitAllAndPush(repoDir: tmp, message: 'x', token: 'ghp_FAKE'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Nothing to commit'))),
      );
    });

    test('pull refuses a dirty tree before it ever reaches the network', () async {
      commit('a.txt', '1', 'first');
      File('${tmp.path}/a.txt').writeAsStringSync('dirty');
      expect(
        () => service.pullFastForward(repoDir: tmp, token: 'ghp_FAKE'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('uncommitted change'))),
      );
    });
  });

  // Push and pull against a bare repo on the local filesystem. Same code
  // path as GitHub minus TLS and credentials — nothing here touches a
  // network, so it is safe in CI.
  group('against a local bare remote', () {
    late Directory bare;
    late Directory work;
    late RepoGitService service;

    Signature sig() => Signature.create(
          name: 'test',
          email: 'test@example.com',
          time: 1756000000,
        );

    void commitIn(Directory dir, String path, String content, String message) {
      File('${dir.path}/$path').writeAsStringSync(content);
      final repo = Repository.open(dir.path);
      final index = repo.index;
      index.add(path);
      index.write();
      Commit.create(
        repo: repo,
        updateRef: 'HEAD',
        author: sig(),
        committer: sig(),
        message: message,
        tree: Tree.lookup(repo: repo, oid: index.writeTree()),
        parents: repo.isEmpty ? [] : [repo.headCommit],
      );
      repo.free();
    }

    setUp(() {
      bare = Directory.systemTemp.createTempSync('git_agent_app_bare');
      work = Directory.systemTemp.createTempSync('git_agent_app_work');
      Repository.init(path: bare.path, bare: true).free();
      Repository.init(path: work.path).free();
      commitIn(work, 'a.txt', 'one', 'first');
      final repo = Repository.open(work.path);
      Remote.create(repo: repo, name: 'origin', url: bare.path).free();
      final branch = repo.head.shorthand;
      final origin = Remote.lookup(repo: repo, name: 'origin');
      origin.push(refspecs: ['refs/heads/$branch:refs/heads/$branch']);
      origin.free();
      repo.free();
      service = RepoGitService(reposRoot: work);
    });

    tearDown(() {
      bare.deleteSync(recursive: true);
      work.deleteSync(recursive: true);
    });

    test('commit & push stages everything pending and lands it on the remote', () async {
      // A mixed change set: one edit, one brand-new file, one deletion.
      File('${work.path}/a.txt').writeAsStringSync('two');
      File('${work.path}/b.txt').writeAsStringSync('new file');
      File('${work.path}/gone.txt').writeAsStringSync('x');
      await service.commitAllAndPush(repoDir: work, message: 'add gone', token: '');
      File('${work.path}/gone.txt').deleteSync();

      final summary = await service.commitAllAndPush(
        repoDir: work,
        message: 'mixed change set',
        token: '',
      );
      expect(summary, contains('pushed to origin/'));

      expect(await service.statusLines(work), ['working tree clean']);
      final log = await service.recentCommits(work);
      expect(log.first.message.trim(), 'mixed change set');

      // The remote actually moved: its tip is our tip.
      final remote = Repository.open(bare.path);
      expect(remote.head.target.sha, log.first.sha);
      remote.free();
    });

    test('an untracked-only change set still counts as something to commit', () async {
      File('${work.path}/only-new.txt').writeAsStringSync('hi');
      expect(await service.statusLines(work), ['??  only-new.txt']);
      await service.commitAllAndPush(repoDir: work, message: 'untracked', token: '');
      expect(await service.statusLines(work), ['working tree clean']);
    });

    test('pull fast-forwards when the remote is ahead', () async {
      expect(
        await service.pullFastForward(repoDir: work, token: ''),
        contains('already up to date'),
      );

      // A second clone pushes a commit, so origin is genuinely ahead.
      final other = Directory.systemTemp.createTempSync('git_agent_app_other');
      addTearDown(() => other.deleteSync(recursive: true));
      Repository.clone(url: bare.path, localPath: other.path).free();
      commitIn(other, 'c.txt', 'from elsewhere', 'remote work');
      final otherRepo = Repository.open(other.path);
      final branch = otherRepo.head.shorthand;
      final otherRemote = Remote.lookup(repo: otherRepo, name: 'origin');
      otherRemote.push(refspecs: ['refs/heads/$branch:refs/heads/$branch']);
      otherRemote.free();
      otherRepo.free();

      final summary = await service.pullFastForward(repoDir: work, token: '');
      expect(summary, contains('Fast-forwarded'));
      expect(File('${work.path}/c.txt').existsSync(), isTrue);
    });

    test('pull refuses to merge diverged history instead of guessing', () async {
      final other = Directory.systemTemp.createTempSync('git_agent_app_other');
      addTearDown(() => other.deleteSync(recursive: true));
      Repository.clone(url: bare.path, localPath: other.path).free();
      commitIn(other, 'c.txt', 'theirs', 'their work');
      final otherRepo = Repository.open(other.path);
      final branch = otherRepo.head.shorthand;
      final otherRemote = Remote.lookup(repo: otherRepo, name: 'origin');
      otherRemote.push(refspecs: ['refs/heads/$branch:refs/heads/$branch']);
      otherRemote.free();
      otherRepo.free();

      // Our own divergent commit, committed but not pushed.
      commitIn(work, 'd.txt', 'ours', 'our work');

      expect(
        () => service.pullFastForward(repoDir: work, token: ''),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('Fast-forward not possible'), contains('diverged')),
        )),
      );
    });
  });

  group('githubAuthHelp', () {
    // The exact string a real device produced when the PAT lacked write scope.
    const real403 =
        'error: git_error_t.GIT_ERROR_HTTP: unexpected http status code: 403';

    test('a 403 push names every cause and the Check access chip', () {
      final help = githubAuthHelp(real403)!;
      expect(help, contains('403'));
      expect(help, contains('refused the write'));
      expect(help, contains('"repo" scope'));
      expect(help, contains('Contents: Read and write'));
      expect(help, contains('expired'));
      expect(help, contains('push access'));
      expect(help, contains('Check access'));
    });

    test('a 401 is a rejected token, not a permission problem', () {
      final help = githubAuthHelp(
        'error: git_error_t.GIT_ERROR_HTTP: unexpected http status code: 401',
      )!;
      expect(help, contains('rejected the token'));
      expect(help, contains('401'));
    });

    test('anything that is not an HTTP auth failure gets no help text', () {
      expect(githubAuthHelp('Nothing to commit — working tree clean.'), isNull);
      expect(githubAuthHelp('unexpected http status code: 500'), isNull);
      // A bare number with no HTTP context must not trigger it.
      expect(githubAuthHelp('403 files changed'), isNull);
    });

    test('help never invents a token into the output', () {
      expect(githubAuthHelp(real403), isNot(contains('ghp_')));
    });
  });
}
