import '../files/file_tree.dart';

/// What a pin points at.
enum PinKind { repo, folder, file }

/// A pinned target that narrows what the LLM is asked to reason about.
///
/// Without a pin, every question ships the repository's whole file tree — a
/// real repo measured 2325 tokens, which an on-device model rejects outright.
/// Pinning a folder or file replaces that with just the relevant slice, so the
/// model sees less noise and spends far less time on prefill.
class PinnedScope {
  final PinKind kind;

  /// Repo-relative path. Empty for [PinKind.repo] — the repository root.
  final String path;

  /// What to show on the pin chip.
  final String label;

  const PinnedScope({
    required this.kind,
    required this.path,
    required this.label,
  });

  const PinnedScope.repo(String fullName)
      : kind = PinKind.repo,
        path = '',
        label = fullName;

  @override
  bool operator ==(Object other) =>
      other is PinnedScope && other.kind == kind && other.path == path;

  @override
  int get hashCode => Object.hash(kind, path);

  /// A short description of the pin for the prompt header.
  String get promptDescription => switch (kind) {
        PinKind.repo => 'the whole repository',
        PinKind.folder => 'the folder "$path"',
        PinKind.file => 'the file "$path"',
      };
}

/// Returns the subtree rooted at [relativePath], or null when no such
/// directory exists — a pin left over from a previous repo, for instance.
FileTreeNode? subtreeAt(FileTreeNode root, String relativePath) {
  if (relativePath.isEmpty) return root;
  if (root.relativePath == relativePath) return root;
  for (final child in root.children) {
    final found = subtreeAt(child, relativePath);
    if (found != null) return found;
  }
  return null;
}

/// Every file path under [node], depth-first.
List<String> filePathsUnder(FileTreeNode node) {
  final paths = <String>[];
  void walk(FileTreeNode n) {
    if (!n.isDirectory) {
      paths.add(n.relativePath);
      return;
    }
    for (final child in n.children) {
      walk(child);
    }
  }

  walk(node);
  return paths;
}
