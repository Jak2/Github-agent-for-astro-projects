import '../files/file_tree.dart';
import '../files/file_tree_text.dart';
import 'pinned_scope.dart';

/// Builds the prompt header and tree text, narrowed to [pinned].
///
/// Without a pin the model gets the whole tree, which is what made real repos
/// unanswerable on-device. A folder pin swaps the tree for that subtree; a file
/// pin swaps it for a single path (the file's content rides in the prompt's
/// file section, which the caller supplies).
///
/// [pinStale] is true when the pin points at a path the tree no longer has. The
/// caller then falls back to the whole tree AND must tell the user — a pin that
/// quietly stops working is worse than no pin at all.
({String header, String treeText, bool pinStale}) buildScopedContext({
  required String repoFullName,
  required FileTreeNode tree,
  required PinnedScope? pinned,
}) {
  final node = pinned == null ? null : subtreeAt(tree, pinned.path);
  final stale = pinned != null && node == null;
  final scope = stale ? null : pinned;

  final header = StringBuffer()
    ..writeln('You are a helpful assistant answering questions about a GitHub repository.')
    ..writeln('Repository: $repoFullName');
  if (scope != null) {
    header.writeln('The user has pinned ${scope.promptDescription}. Answer only about it.');
  }
  header.writeln('File and folder structure:');

  final treeText = switch (scope?.kind) {
    null || PinKind.repo => '${renderFileTreeAsText(tree)}\n',
    PinKind.folder => '${renderFileTreeAsText(node!)}\n',
    PinKind.file => '${scope!.path}\n',
  };

  return (header: header.toString(), treeText: treeText, pinStale: stale);
}
