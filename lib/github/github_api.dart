import 'dart:convert';

import 'package:dio/dio.dart';
import 'github_repo.dart';

List<GithubRepo> parseRepoListJson(List<dynamic> json) {
  final repos = <GithubRepo>[];
  for (final entry in json) {
    if (entry is! Map) continue;
    final fullName = entry['full_name'];
    final cloneUrl = entry['clone_url'];
    final defaultBranch = entry['default_branch'];
    if (fullName is! String || cloneUrl is! String || defaultBranch is! String) {
      continue;
    }
    repos.add(GithubRepo(
      fullName: fullName,
      cloneUrl: cloneUrl,
      defaultBranch: defaultBranch,
    ));
  }
  return repos;
}

/// One `git-receive-pack` probe: the HTTP status GitHub answered with, or the
/// reason we never got one. Never carries a message from the wire — see
/// [GithubApi._probePush].
typedef PushProbe = ({int? status, String? error});

String _probeReads(PushProbe probe) => switch (probe) {
      (status: _, error: final String e) => 'could not be checked ($e)',
      (status: 200, error: _) => 'CAN push (HTTP 200)',
      (status: 403, error: _) => 'authenticated but FORBIDDEN to write (HTTP 403)',
      (status: 401, error: _) => 'credential REJECTED (HTTP 401)',
      (status: final s, error: _) => 'unexpected HTTP $s',
    };

/// Turns the probe responses into the lines the chip renders.
///
/// Pure on purpose: the whole point of this check is that it must be exactly
/// right about *why* a push was refused, which is not something to verify by
/// pushing to a real repo. Nothing here can render the token — it only ever
/// sees status codes and the scopes header.
///
/// [asToken] and [asXAccessToken] are the same repo probed with the two
/// credential formats: username=token (what this app sends) and
/// username=x-access-token (GitHub's documented form). Comparing them is what
/// separates "your token lacks write" from "our code sends it wrong".
List<String> accessVerdictLines({
  required String repoFullName,
  required int userStatus,
  required String? scopesHeader,
  required int repoStatus,
  required PushProbe asToken,
  required PushProbe asXAccessToken,
}) {
  if (userStatus != 200) {
    return [
      'Token: REJECTED by GitHub (HTTP $userStatus).',
      'It is invalid, revoked, or expired. Replace it in Config.',
    ];
  }

  final scopes = scopesHeader?.trim() ?? '';
  final lines = <String>[
    'Token: valid — GitHub accepted it.',
    scopes.isEmpty
        // A classic PAT always reports its scopes here; a fine-grained one
        // reports nothing, which is not the same as having no permissions.
        ? 'Scopes: none reported — this is a fine-grained token '
            '(scopes are not reported for those).'
        : 'Scopes: $scopes',
  ];

  // Deliberately NO line for the repo's `permissions.push`: that field is the
  // account's permission on the repo, not the token's, so it reads GRANTED
  // next to a push that 403s. The probes below are what a push actually does.
  switch (repoStatus) {
    case 200:
      break;
    case 404:
      lines.add(
        'Repo $repoFullName: not visible to this token (HTTP 404) — a '
        'fine-grained token must list this repository, or a classic one '
        'needs the "repo" scope for it.',
      );
    default:
      lines.add('Repo $repoFullName: could not be read (HTTP $repoStatus).');
  }

  lines.add('Push probe (username = token, what this app sends): '
      '${_probeReads(asToken)}');
  lines.add('Push probe (username = x-access-token, GitHub\'s documented form): '
      '${_probeReads(asXAccessToken)}');

  final a = asToken.status;
  final b = asXAccessToken.status;
  if (asToken.error != null || asXAccessToken.error != null) {
    lines.add(
      'Verdict: COULD NOT CHECK — the push probe never reached GitHub, so '
      'nothing here says your push is fine. Check the connection and retry.',
    );
  } else if (a == 200 && b == 200) {
    lines.add(
      'Verdict: this token CAN push to $repoFullName. A 403 on Commit & push '
      'is coming from somewhere else (branch protection, a ruleset, or SSO '
      'authorisation) — this check does not explain it.',
    );
  } else if (b == 200) {
    lines.add(
      'Verdict: OUR CREDENTIAL FORMAT IS THE BUG, not your token. The token '
      'pushes fine as x-access-token but is refused the way this app sends '
      'it. Fix is in our code (repo_git_service.dart), not in Config.',
    );
  } else if (a == 200) {
    lines.add(
      'Verdict: this token CAN push in the format this app sends. The '
      'documented x-access-token form is refused, which is a GitHub-side '
      'quirk, not your token — a 403 on Commit & push is coming from '
      'elsewhere.',
    );
  } else if (a == 401 || b == 401) {
    lines.add(
      'Verdict: GitHub rejected the credential outright (401). The token is '
      'not usable for git over HTTPS — re-enter it in Config.',
    );
  } else {
    lines.add(
      'Verdict: this TOKEN lacks write access to $repoFullName — both '
      'credential formats were refused, so our code is not the problem.',
    );
    lines.add(
      'Fix: grant Contents: Read and write (fine-grained PAT) or the "repo" '
      'scope (classic PAT), then re-enter the token in Config.',
    );
  }
  return lines;
}

class GithubApi {
  final Dio client;
  final String token;

  GithubApi({required this.client, required this.token});

  Options _authOptions() => Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
        },
        // Every status is data here: a 401 or 404 is the answer, not a crash.
        validateStatus: (_) => true,
      );

  /// Asks GitHub the exact question `git push` asks: the `git-receive-pack`
  /// service on the clone URL, with HTTP Basic auth. 200 means this credential
  /// really can write; 403 means authenticated but not permitted; 401 means the
  /// credential itself was refused.
  Future<PushProbe> _probePush(String repoFullName, String username) async {
    try {
      final res = await client.get(
        'https://github.com/$repoFullName.git/info/refs',
        queryParameters: {'service': 'git-receive-pack'},
        options: Options(
          headers: {
            'Authorization':
                'Basic ${base64Encode(utf8.encode('$username:$token'))}',
          },
          validateStatus: (_) => true,
          // A redirect's status is the answer too; chasing it drops the header.
          followRedirects: false,
        ),
      );
      return (status: res.statusCode, error: null);
    } catch (e) {
      // Only the *kind* of failure, never `e` itself: a DioException renders
      // its request, and the token is in that request's headers.
      return (
        status: null,
        error: e is DioException ? e.type.name : 'no response',
      );
    }
  }

  /// Why a push was refused, asked over HTTP rather than libgit2 — libgit2 only
  /// ever says "403". Probes both credential formats so a failure can be pinned
  /// on the token or on this app's credential format.
  Future<List<String>> checkAccess(String repoFullName) async {
    final user = await client.get('https://api.github.com/user', options: _authOptions());
    final repo = await client.get(
      'https://api.github.com/repos/$repoFullName',
      options: _authOptions(),
    );
    return accessVerdictLines(
      repoFullName: repoFullName,
      userStatus: user.statusCode ?? 0,
      scopesHeader: user.headers.value('x-oauth-scopes'),
      repoStatus: repo.statusCode ?? 0,
      asToken: await _probePush(repoFullName, token),
      asXAccessToken: await _probePush(repoFullName, 'x-access-token'),
    );
  }

  Future<List<GithubRepo>> listRepos() async {
    final response = await client.get(
      'https://api.github.com/user/repos',
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
      }),
      queryParameters: {'per_page': 100, 'sort': 'updated'},
    );
    return parseRepoListJson(response.data as List<dynamic>);
  }
}
