// test/git/git_identity_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_git/git/git_identity.dart';
import 'package:pocket_git/github/github_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the identity is whichever GitHub account is signed in', () {
    final identity = CommitIdentity.fromGithubUser(
      const GithubUser(login: 'jak2', name: 'Jaya', email: 'j@example.com'),
    );
    expect(identity.name, 'Jaya');
    expect(identity.email, 'j@example.com');
  });

  test('saved identity round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    expect(await loadCommitIdentity(prefs), isNull);

    await saveCommitIdentity(
      prefs,
      const CommitIdentity(name: 'Jaya', email: 'j@example.com'),
    );
    final loaded = await loadCommitIdentity(prefs);
    expect(loaded!.name, 'Jaya');
    expect(loaded.email, 'j@example.com');

    await clearCommitIdentity(prefs);
    expect(await loadCommitIdentity(prefs), isNull);
  });

  test('a half-written pair is treated as no identity at all', () async {
    SharedPreferences.setMockInitialValues({'commit_author_name': 'Jaya'});
    final prefs = await SharedPreferences.getInstance();
    expect(await loadCommitIdentity(prefs), isNull);
  });
}
