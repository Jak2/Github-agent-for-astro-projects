// test/git/repo_paths_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/git/repo_paths.dart';

void main() {
  test('localCloneDirName replaces slashes with underscores', () {
    expect(localCloneDirName('jak2/git_agent_app'), 'jak2_git_agent_app');
  });

  test('repoDirectory returns a directory under reposRoot named by localCloneDirName', () async {
    final tempRoot = await Directory.systemTemp.createTemp('repos_root_test');
    addTearDown(() => tempRoot.delete(recursive: true));

    final dir = await repoDirectory(tempRoot, 'jak2/git_agent_app');

    expect(dir.path, '${tempRoot.path}/jak2_git_agent_app');
  });
}
