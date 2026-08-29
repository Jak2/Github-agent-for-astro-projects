// lib/git/git_identity.dart
import 'package:shared_preferences/shared_preferences.dart';

import '../github/github_api.dart';

const _nameKey = 'commit_author_name';
const _emailKey = 'commit_author_email';

/// Who commits are attributed to: the signed-in GitHub account.
///
/// Cached on the device so a commit still works with no network — only the
/// push needs one.
class CommitIdentity {
  final String name;
  final String email;

  const CommitIdentity({required this.name, required this.email});

  factory CommitIdentity.fromGithubUser(GithubUser user) =>
      CommitIdentity(name: user.name, email: user.email);
}

/// The cached identity, or null when nothing usable is stored.
///
/// A half-written pair (name but no email) is treated as absent: a commit
/// with an empty author field is not something to paper over.
Future<CommitIdentity?> loadCommitIdentity(SharedPreferences prefs) async {
  final name = prefs.getString(_nameKey);
  final email = prefs.getString(_emailKey);
  if (name == null || email == null || name.isEmpty || email.isEmpty) {
    return null;
  }
  return CommitIdentity(name: name, email: email);
}

Future<void> saveCommitIdentity(
  SharedPreferences prefs,
  CommitIdentity identity,
) async {
  await prefs.setString(_nameKey, identity.name);
  await prefs.setString(_emailKey, identity.email);
}

Future<void> clearCommitIdentity(SharedPreferences prefs) async {
  await prefs.remove(_nameKey);
  await prefs.remove(_emailKey);
}
