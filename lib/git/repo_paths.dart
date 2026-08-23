// lib/git/repo_paths.dart
import 'dart:io';
import 'package:path/path.dart' as p;

String localCloneDirName(String fullName) => fullName.replaceAll('/', '_');

Future<Directory> repoDirectory(Directory reposRoot, String fullName) async {
  return Directory(p.join(reposRoot.path, localCloneDirName(fullName)));
}
