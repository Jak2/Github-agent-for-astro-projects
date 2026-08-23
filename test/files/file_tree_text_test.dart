// test/files/file_tree_text_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/files/file_tree.dart';
import 'package:git_agent_app/files/file_tree_text.dart';

FileTreeNode _file(String name, String relativePath) =>
    FileTreeNode(name: name, relativePath: relativePath, isDirectory: false, children: const []);

FileTreeNode _dir(String name, String relativePath, List<FileTreeNode> children) =>
    FileTreeNode(name: name, relativePath: relativePath, isDirectory: true, children: children);

void main() {
  test('renders a flat list of files with no indentation', () {
    final root = _dir('repo', '', [
      _file('README.md', 'README.md'),
      _file('config.dart', 'config.dart'),
    ]);
    final text = renderFileTreeAsText(root);
    expect(text, 'README.md\nconfig.dart\n');
  });

  test('renders nested directories with two-space indent per depth level', () {
    final root = _dir('repo', '', [
      _file('README.md', 'README.md'),
      _dir('docs', 'docs', [
        _dir('posts', 'docs/posts', []),
      ]),
      _dir('src', 'src', [
        _file('main.dart', 'src/main.dart'),
      ]),
    ]);
    final text = renderFileTreeAsText(root);
    expect(text, 'README.md\ndocs/\n  posts/\nsrc/\n  main.dart\n');
  });

  test('directories get a trailing slash, files do not', () {
    final root = _dir('repo', '', [_dir('lib', 'lib', []), _file('a.txt', 'a.txt')]);
    final text = renderFileTreeAsText(root);
    expect(text, contains('lib/\n'));
    expect(text, isNot(contains('a.txt/')));
  });

  test('an empty root produces an empty string', () {
    final root = _dir('repo', '', []);
    expect(renderFileTreeAsText(root), '');
  });
}
