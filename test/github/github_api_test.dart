// test/github/github_api_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_git/github/github_api.dart';

void main() {
  test('parseRepoListJson maps GitHub API fields', () {
    final json = [
      {
        'full_name': 'jak2/pocket_git',
        'clone_url': 'https://github.com/jak2/pocket_git.git',
        'default_branch': 'main',
      },
      {
        'full_name': 'jak2/other_repo',
        'clone_url': 'https://github.com/jak2/other_repo.git',
        'default_branch': 'master',
      },
    ];

    final repos = parseRepoListJson(json);

    expect(repos, hasLength(2));
    expect(repos[0].fullName, 'jak2/pocket_git');
    expect(repos[0].cloneUrl, 'https://github.com/jak2/pocket_git.git');
    expect(repos[0].defaultBranch, 'main');
    expect(repos[1].fullName, 'jak2/other_repo');
  });

  test('parseRepoListJson skips entries missing required fields', () {
    final json = [
      {'full_name': 'jak2/missing_clone_url', 'default_branch': 'main'},
      {
        'full_name': 'jak2/valid',
        'clone_url': 'https://github.com/jak2/valid.git',
        'default_branch': 'main',
      },
    ];

    final repos = parseRepoListJson(json);

    expect(repos, hasLength(1));
    expect(repos[0].fullName, 'jak2/valid');
  });

  group('accessVerdictLines', () {
    List<String> verdict({
      int userStatus = 200,
      String? scopesHeader,
      int repoStatus = 200,
      bool? pushPermission,
    }) =>
        accessVerdictLines(
          repoFullName: 'jak2/pocket_git',
          userStatus: userStatus,
          scopesHeader: scopesHeader,
          repoStatus: repoStatus,
          pushPermission: pushPermission,
        );

    test('a rejected token stops at the token and says to replace it', () {
      final lines = verdict(userStatus: 401);
      expect(lines.first, contains('REJECTED'));
      expect(lines.first, contains('401'));
      expect(lines.join('\n'), contains('expired'));
      // Nothing about the repo can be trusted once the token is dead.
      expect(lines.join('\n'), isNot(contains('Push to')));
    });

    test('an empty scopes header means fine-grained, not "no permissions"', () {
      final lines = verdict(scopesHeader: '', pushPermission: true).join('\n');
      expect(lines, contains('fine-grained'));
      expect(lines, isNot(contains('Scopes: none reported — this is a classic')));
    });

    test('a classic token reports its scopes verbatim', () {
      final lines = verdict(scopesHeader: 'repo, gist', pushPermission: true).join('\n');
      expect(lines, contains('Scopes: repo, gist'));
      expect(lines, isNot(contains('fine-grained')));
    });

    test('push granted reads as granted and offers no fix', () {
      final lines = verdict(scopesHeader: 'repo', pushPermission: true).join('\n');
      expect(lines, contains('Token: valid'));
      expect(lines, contains('Push to jak2/pocket_git: GRANTED.'));
      expect(lines, isNot(contains('Fix:')));
    });

    test('push denied names both PAT fixes', () {
      final lines = verdict(scopesHeader: 'gist', pushPermission: false).join('\n');
      expect(lines, contains('DENIED'));
      expect(lines, contains('"repo" scope'));
      expect(lines, contains('Contents: Read and write'));
    });

    test('a 404 on the repo is invisibility, not absence of push rights', () {
      final lines = verdict(scopesHeader: '', repoStatus: 404).join('\n');
      expect(lines, contains('not visible to this token'));
      expect(lines, contains('404'));
      expect(lines, contains('Fix:'));
    });

    test('a missing permissions block says so rather than guessing', () {
      final lines = verdict(scopesHeader: 'repo').join('\n');
      expect(lines, contains('not reported by GitHub'));
    });

    test('no verdict line can ever carry the token', () {
      final lines = verdict(scopesHeader: 'repo', pushPermission: false).join('\n');
      expect(lines, isNot(contains('ghp_')));
      expect(lines, isNot(contains('Bearer')));
    });
  });

  group('parseUserJson', () {
    test('reads the account straight through when GitHub gives everything', () {
      final user = parseUserJson({
        'login': 'jak2',
        'id': 12345,
        'name': 'Jaya Arun Kumar Tulluri',
        'email': 'jaya@example.com',
      });
      expect(user.login, 'jak2');
      expect(user.name, 'Jaya Arun Kumar Tulluri');
      expect(user.email, 'jaya@example.com');
    });

    test('a hidden email falls back to the GitHub noreply address', () {
      final user = parseUserJson({'login': 'jak2', 'id': 12345, 'email': null});
      expect(user.email, '12345+jak2@users.noreply.github.com');
    });

    test('a missing profile name falls back to the login', () {
      final user = parseUserJson({'login': 'jak2', 'id': 1, 'name': null});
      expect(user.name, 'jak2');
    });

    test('a blank name or email is treated as absent, not committed as blank', () {
      final user = parseUserJson({
        'login': 'jak2',
        'id': 1,
        'name': '   ',
        'email': '',
      });
      expect(user.name, 'jak2');
      expect(user.email, '1+jak2@users.noreply.github.com');
    });

    test('no id still yields a usable noreply address', () {
      final user = parseUserJson({'login': 'jak2'});
      expect(user.email, 'jak2@users.noreply.github.com');
    });

    test('a response without a login is refused rather than half-parsed', () {
      expect(() => parseUserJson({'id': 1}), throwsA(isA<StateError>()));
    });
  });
}
