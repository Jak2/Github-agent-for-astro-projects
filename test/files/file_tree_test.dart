// test/files/file_tree_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/files/file_tree.dart';

void main() {
  test('buildFileTree reflects nested directory structure with relative paths', () async {
    final root = await Directory.systemTemp.createTemp('file_tree_test');
    addTearDown(() => root.delete(recursive: true));

    await File('${root.path}/README.md').writeAsString('hi');
    final docsDir = await Directory('${root.path}/docs').create();
    await File('${docsDir.path}/guide.md').writeAsString('guide');

    final tree = await buildFileTree(root);

    expect(tree.isDirectory, isTrue);
    expect(tree.relativePath, '');

    final names = tree.children.map((c) => c.name).toSet();
    expect(names, {'README.md', 'docs'});

    final docsNode = tree.children.firstWhere((c) => c.name == 'docs');
    expect(docsNode.isDirectory, isTrue);
    expect(docsNode.children, hasLength(1));
    expect(docsNode.children.first.name, 'guide.md');
    expect(docsNode.children.first.relativePath, 'docs/guide.md');
    expect(docsNode.children.first.isDirectory, isFalse);
  });

  test('buildFileTree skips the .git directory', () async {
    final root = await Directory.systemTemp.createTemp('file_tree_test');
    addTearDown(() => root.delete(recursive: true));

    await Directory('${root.path}/.git').create();
    await File('${root.path}/README.md').writeAsString('hi');

    final tree = await buildFileTree(root);

    expect(tree.children.map((c) => c.name), ['README.md']);
  });
}
