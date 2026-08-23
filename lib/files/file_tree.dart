// lib/files/file_tree.dart
import 'dart:io';
import 'package:path/path.dart' as p;

class FileTreeNode {
  final String name;
  final String relativePath;
  final bool isDirectory;
  final List<FileTreeNode> children;

  FileTreeNode({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.children,
  });
}

Future<FileTreeNode> buildFileTree(Directory root) async {
  return _buildNode(root, root, '');
}

Future<FileTreeNode> _buildNode(Directory root, Directory dir, String relativePath) async {
  final children = <FileTreeNode>[];
  final entries = await dir.list().toList();
  entries.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

  for (final entry in entries) {
    final name = p.basename(entry.path);
    if (name == '.git') continue;
    final childRelativePath = relativePath.isEmpty ? name : '$relativePath/$name';

    if (entry is Directory) {
      children.add(await _buildNode(root, entry, childRelativePath));
    } else if (entry is File) {
      children.add(FileTreeNode(
        name: name,
        relativePath: childRelativePath,
        isDirectory: false,
        children: const [],
      ));
    }
  }

  return FileTreeNode(
    name: p.basename(dir.path),
    relativePath: relativePath,
    isDirectory: true,
    children: children,
  );
}
