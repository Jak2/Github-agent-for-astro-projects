import 'package:path/path.dart' as p;

/// Resolves a chat instruction like "save it in docs/posts/" or
/// "put it at content/blog/my-post.md" into a repo-relative path.
/// Returns null when no path can be found in [instruction].
///
/// Rule: scan all whitespace-delimited tokens and pick the last one that
/// looks like a path (contains a "/"). Later mentions override earlier ones.
/// If it ends with "/", or has no file extension, treat it as a target
/// folder and append the source file's name with a ".md" extension.
/// Otherwise treat it as the full target file path as-is.
String? resolveSavePath({required String instruction, required String sourceRelativePath}) {
  final tokens = instruction.split(RegExp(r'\s+'));
  String? candidate;
  for (final token in tokens) {
    final cleaned = token.trim();
    if (cleaned.isEmpty) continue;
    if (cleaned.contains('/')) {
      candidate = cleaned;
    }
  }
  if (candidate == null) return null;

  final looksLikeFolder = candidate.endsWith('/') || p.extension(candidate).isEmpty;
  String resolved;
  if (!looksLikeFolder) {
    resolved = candidate;
  } else {
    final sourceBaseName = p.basenameWithoutExtension(sourceRelativePath);
    final folder = candidate.endsWith('/') ? candidate.substring(0, candidate.length - 1) : candidate;
    resolved = '$folder/$sourceBaseName.md';
  }

  if (_isUnsafePath(resolved)) return null;
  return resolved;
}

/// Rejects absolute paths and paths containing a ".." segment, guarding
/// against writes outside the cloned repo directory.
bool _isUnsafePath(String path) {
  if (path.startsWith('/')) return true;
  final segments = path.split('/');
  return segments.contains('..');
}
