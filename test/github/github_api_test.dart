// test/github/github_api_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/github/github_api.dart';

void main() {
  test('parseRepoListJson maps GitHub API fields', () {
    final json = [
      {
        'full_name': 'jak2/git_agent_app',
        'clone_url': 'https://github.com/jak2/git_agent_app.git',
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
    expect(repos[0].fullName, 'jak2/git_agent_app');
    expect(repos[0].cloneUrl, 'https://github.com/jak2/git_agent_app.git');
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
    const ok = (status: 200, error: null);
    const forbidden = (status: 403, error: null);
    const unauthorized = (status: 401, error: null);

    List<String> verdict({
      int userStatus = 200,
      String? scopesHeader,
      int repoStatus = 200,
      PushProbe asToken = forbidden,
      PushProbe asXAccessToken = forbidden,
    }) =>
        accessVerdictLines(
          repoFullName: 'jak2/git_agent_app',
          userStatus: userStatus,
          scopesHeader: scopesHeader,
          repoStatus: repoStatus,
          asToken: asToken,
          asXAccessToken: asXAccessToken,
        );

    test('a rejected token stops at the token and says to replace it', () {
      final lines = verdict(userStatus: 401);
      expect(lines.first, contains('REJECTED'));
      expect(lines.first, contains('401'));
      expect(lines.join('\n'), contains('expired'));
      // Nothing about the repo can be trusted once the token is dead.
      expect(lines.join('\n'), isNot(contains('Push probe')));
    });

    test('an empty scopes header means fine-grained, not "no permissions"', () {
      final lines = verdict(scopesHeader: '', asToken: ok, asXAccessToken: ok).join('\n');
      expect(lines, contains('fine-grained'));
      expect(lines, isNot(contains('Scopes: none reported — this is a classic')));
    });

    test('a classic token reports its scopes verbatim', () {
      final lines = verdict(scopesHeader: 'repo, gist', asToken: ok, asXAccessToken: ok).join('\n');
      expect(lines, contains('Scopes: repo, gist'));
      expect(lines, isNot(contains('fine-grained')));
    });

    test('the account-level permissions.push line is gone for good', () {
      // The whole bug: that line read GRANTED while the push 403d.
      final lines = verdict(scopesHeader: '', repoStatus: 200).join('\n');
      expect(lines, isNot(contains('GRANTED')));
      expect(lines, isNot(contains('permissions')));
    });

    test('both formats forbidden blames the token, not our code', () {
      final lines = verdict(scopesHeader: '').join('\n');
      expect(lines, contains('this TOKEN lacks write access'));
      expect(lines, contains('both'));
      expect(lines, contains('Contents: Read and write'));
      expect(lines, contains('"repo" scope'));
      expect(lines, isNot(contains('OUR CREDENTIAL FORMAT')));
    });

    test('our format failing while x-access-token works blames our code', () {
      final lines = verdict(scopesHeader: '', asXAccessToken: ok).join('\n');
      expect(lines, contains('OUR CREDENTIAL FORMAT IS THE BUG'));
      expect(lines, contains('repo_git_service.dart'));
      // Must not send the user off to re-issue a token that is actually fine.
      expect(lines, isNot(contains('Fix: grant Contents')));
    });

    test('both formats pushing admits the check did not explain the 403', () {
      final lines = verdict(scopesHeader: 'repo', asToken: ok, asXAccessToken: ok).join('\n');
      expect(lines, contains('CAN push to jak2/git_agent_app'));
      expect(lines, contains('does not explain it'));
      expect(lines, isNot(contains('Fix:')));
    });

    test('only our format working leaves the push code alone', () {
      final lines = verdict(scopesHeader: 'repo', asToken: ok).join('\n');
      expect(lines, contains('CAN push in the format this app sends'));
      expect(lines, isNot(contains('OUR CREDENTIAL FORMAT')));
    });

    test('a 401 from the probe is a rejected credential, not a permission', () {
      final lines = verdict(scopesHeader: '', asToken: unauthorized, asXAccessToken: unauthorized)
          .join('\n');
      expect(lines, contains('rejected the credential outright (401)'));
      expect(lines, isNot(contains('lacks write access')));
    });

    test('a probe that never reached GitHub renders a visible could-not-check', () {
      final lines = verdict(
        scopesHeader: '',
        asToken: (status: null, error: 'connectionError'),
        asXAccessToken: (status: null, error: 'connectionError'),
      ).join('\n');
      expect(lines, contains('COULD NOT CHECK'));
      expect(lines, contains('connectionError'));
      // Silence would read as a pass; it must not.
      expect(lines, isNot(contains('CAN push')));
    });

    test('one probe erroring cannot be reported as a clean result', () {
      final lines =
          verdict(scopesHeader: '', asToken: ok, asXAccessToken: (status: null, error: 'timeout'))
              .join('\n');
      expect(lines, contains('COULD NOT CHECK'));
    });

    test('an unexpected status is reported verbatim rather than guessed at', () {
      final lines = verdict(scopesHeader: '', asToken: (status: 500, error: null)).join('\n');
      expect(lines, contains('unexpected HTTP 500'));
    });

    test('a 404 on the repo is invisibility, not absence of push rights', () {
      final lines = verdict(scopesHeader: '', repoStatus: 404).join('\n');
      expect(lines, contains('not visible to this token'));
      expect(lines, contains('404'));
    });

    test('no verdict line can ever carry the token', () {
      final lines = verdict(scopesHeader: 'repo').join('\n');
      expect(lines, isNot(contains('ghp_')));
      expect(lines, isNot(contains('Bearer')));
      expect(lines, isNot(contains('Basic')));
    });
  });

  group('checkAccess probes', () {
    test('probes git-receive-pack with Basic auth in both formats, token never in the URL',
        () async {
      const token = 'ghp_secrettoken';
      final seen = <RequestOptions>[];
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((options) {
        seen.add(options);
        final body = options.path.contains('api.github.com/user')
            ? '{"login": "jak2"}'
            : '{"full_name": "jak2/Blog"}';
        return ResponseBody.fromString(body, options.path.contains('info/refs') ? 403 : 200,
            headers: {
              'content-type': ['application/json']
            });
      });

      final lines = await GithubApi(client: dio, token: token).checkAccess('jak2/Blog');

      final probes = seen.where((o) => o.path.contains('info/refs')).toList();
      expect(probes, hasLength(2));
      for (final p in probes) {
        expect(p.queryParameters['service'], 'git-receive-pack');
        expect(p.uri.toString(), isNot(contains(token)));
        expect(p.headers['Authorization'], startsWith('Basic '));
      }
      expect(probes[0].headers['Authorization'],
          'Basic ${base64Encode(utf8.encode('$token:$token'))}');
      expect(probes[1].headers['Authorization'],
          'Basic ${base64Encode(utf8.encode('x-access-token:$token'))}');
      expect(lines.join('\n'), isNot(contains(token)));
      expect(lines.join('\n'), contains('this TOKEN lacks write access'));
    });

    test('a probe that throws is reported, not swallowed', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((options) {
        if (options.path.contains('info/refs')) {
          throw DioException.connectionError(
            requestOptions: options,
            reason: 'no route to host',
          );
        }
        return ResponseBody.fromString('{}', 200, headers: {
          'content-type': ['application/json']
        });
      });

      final lines = (await GithubApi(client: dio, token: 'ghp_x').checkAccess('jak2/Blog')).join('\n');

      expect(lines, contains('COULD NOT CHECK'));
      expect(lines, contains('connectionError'));
      // The reason string comes off the wire — never render it.
      expect(lines, isNot(contains('no route to host')));
    });
  });
}

class _FakeAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) handler;

  _FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
          Future<void>? cancelFuture) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}
