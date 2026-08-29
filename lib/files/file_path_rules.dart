/// Rules for every repo-relative path the user can type.
///
/// A path typed into a "New file" or "Rename" popup is untrusted input that
/// runs against a real clone, so `..`, absolute paths and `.git` are rejected
/// here — once, for every caller.
library;

/// Why [path] must not be written, or null when it is safe.
String? filePathRejection(String path) {
  if (path.trim().isEmpty) return 'no path given';
  if (path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) {
    return 'absolute paths are not allowed';
  }
  if (path.contains('\\')) return 'use forward slashes';
  final segments = path.split('/');
  if (segments.contains('..')) return 'paths may not escape the repository';
  if (segments.contains('.git')) return 'writing inside .git is not allowed';
  if (path.trimRight().endsWith('/')) return 'that is a folder, not a file';
  return null;
}

/// Drops empty and `.` segments. Only ever applied to a path
/// [filePathRejection] has already cleared.
String normaliseFilePath(String path) =>
    path.split('/').where((s) => s.isNotEmpty && s != '.').join('/');
