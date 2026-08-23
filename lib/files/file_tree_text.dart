// lib/files/file_tree_text.dart
import 'file_tree.dart';

String renderFileTreeAsText(FileTreeNode root) {
  final buffer = StringBuffer();
  _renderChildren(root, 0, buffer);
  return buffer.toString();
}

void _renderChildren(FileTreeNode node, int depth, StringBuffer buffer) {
  for (final child in node.children) {
    buffer.writeln('${'  ' * depth}${child.name}${child.isDirectory ? '/' : ''}');
    if (child.isDirectory) {
      _renderChildren(child, depth + 1, buffer);
    }
  }
}
