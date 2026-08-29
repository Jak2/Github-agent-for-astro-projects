// test/git/repo_paths_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_git/git/repo_paths.dart';

void main() {
  test('repoDirectory nests the clone under repos/owner/name', () async {
    final tempRoot = await Directory.systemTemp.createTemp('repos_root_test');
    addTearDown(() => tempRoot.delete(recursive: true));

    final dir = await repoDirectory(tempRoot, 'jak2/pocket_git');

    expect(dir.path, '${tempRoot.path}/repos/jak2/pocket_git');
  });

  test('two repos whose flattened names would collide stay separate', () async {
    final tempRoot = await Directory.systemTemp.createTemp('repos_root_test');
    addTearDown(() => tempRoot.delete(recursive: true));

    final a = await repoDirectory(tempRoot, 'jak2/pocket_git');
    final b = await repoDirectory(tempRoot, 'jak2_pocket/git');

    expect(a.path, isNot(b.path));
  });

  test('a full name that tries to escape the root is stripped, not honoured', () async {
    final tempRoot = await Directory.systemTemp.createTemp('repos_root_test');
    addTearDown(() => tempRoot.delete(recursive: true));

    final dir = await repoDirectory(tempRoot, '../../etc/passwd');

    expect(dir.path.startsWith('${tempRoot.path}/repos/'), isTrue);
    expect(dir.path, isNot(contains('..')));
  });
}
