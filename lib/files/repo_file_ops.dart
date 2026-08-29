// lib/files/repo_file_ops.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'file_path_rules.dart';

/// Create/read/rename/delete inside one clone.
///
/// Every path here comes from a text field, so it is untrusted input running
/// against a real checkout. [filePathRejection] is the single gate: it rejects
/// absolute paths, `..` and anything under `.git`, so nothing written through
/// this file can land outside [repoDir].
File _resolve(Directory repoDir, String relativePath) {
  final reason = filePathRejection(relativePath);
  if (reason != null) throw ArgumentError(reason);
  return File(p.join(repoDir.path, normaliseFilePath(relativePath)));
}

Future<File> writeRepoFile(
  Directory repoDir,
  String relativePath,
  String content,
) async {
  final file = _resolve(repoDir, relativePath);
  await file.parent.create(recursive: true);
  return file.writeAsString(content);
}

Future<String> readRepoFile(Directory repoDir, String relativePath) =>
    _resolve(repoDir, relativePath).readAsString();

Future<bool> repoFileExists(Directory repoDir, String relativePath) =>
    _resolve(repoDir, relativePath).exists();

Future<void> deleteRepoFile(Directory repoDir, String relativePath) async {
  final file = _resolve(repoDir, relativePath);
  if (await file.exists()) await file.delete();
}

/// Throws [StateError] when the target exists — an overwrite here silently
/// destroys a file the user did not name.
Future<void> renameRepoFile(
  Directory repoDir,
  String fromRelativePath,
  String toRelativePath, {
  bool overwrite = false,
}) async {
  final from = _resolve(repoDir, fromRelativePath);
  final to = _resolve(repoDir, toRelativePath);
  if (!await from.exists()) {
    throw StateError('$fromRelativePath does not exist.');
  }
  if (await to.exists() && !overwrite) {
    throw StateError('$toRelativePath already exists.');
  }
  await to.parent.create(recursive: true);
  await from.rename(to.path);
}

/// Copies a file the user picked off the device into the clone.
///
/// The source is an absolute device path on purpose — it is outside the repo.
/// Only the target is repo-relative and validated.
Future<File> importFileInto(
  Directory repoDir,
  String sourceAbsolutePath,
  String targetRelativePath,
) async {
  final target = _resolve(repoDir, targetRelativePath);
  await target.parent.create(recursive: true);
  return File(sourceAbsolutePath).copy(target.path);
}

/// A NUL byte in the first 8KB, the same heuristic git uses.
///
/// The text editor must refuse binaries: reading a PNG as UTF-8 and writing it
/// back corrupts it beyond recovery.
Future<bool> looksBinary(Directory repoDir, String relativePath) async {
  final file = _resolve(repoDir, relativePath);
  final handle = await file.open();
  try {
    final Uint8List head = await handle.read(8192);
    return head.contains(0);
  } finally {
    await handle.close();
  }
}
