// lib/git/repo_paths.dart
import 'dart:io';
import 'package:path/path.dart' as p;

/// `owner/name` becomes `repos/owner/name` rather than `owner_name`:
/// flattening the slash is not injective — `a/b_c` and `a_b/c` collapse onto
/// the same directory, and the second repo would push to the first one's
/// remote.
Future<Directory> repoDirectory(Directory reposRoot, String fullName) async {
  final segments = fullName.split('/').where((s) => s.isNotEmpty && s != '..');
  return Directory(p.joinAll([reposRoot.path, 'repos', ...segments]));
}
