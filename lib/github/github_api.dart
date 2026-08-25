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

/// Turns the two probe responses into the lines the chip renders.
///
/// Pure on purpose: the whole point of this check is that it must be exactly
/// right about *why* a push was refused, which is not something to verify by
/// pushing to a real repo. Nothing here can render the token — it only ever
/// sees status codes, the scopes header and a bool.
List<String> accessVerdictLines({
  required String repoFullName,
  required int userStatus,
  required String? scopesHeader,
  required int repoStatus,
  required bool? pushPermission,
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

  switch (repoStatus) {
    case 200:
      lines.add(switch (pushPermission) {
        true => 'Push to $repoFullName: GRANTED.',
        false => 'Push to $repoFullName: DENIED — this token cannot write here.',
        null => 'Push to $repoFullName: not reported by GitHub.',
      });
    case 404:
      lines.add(
        'Repo $repoFullName: not visible to this token (HTTP 404) — a '
        'fine-grained token must list this repository, or a classic one '
        'needs the "repo" scope for it.',
      );
    default:
      lines.add('Repo $repoFullName: could not be read (HTTP $repoStatus).');
  }

  if (pushPermission != true) {
    lines.add(
      'Fix: classic PAT needs the "repo" scope; fine-grained PAT needs '
      'Contents: Read and write on this repository.',
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

  /// Why a push was refused, asked over the REST API rather than libgit2 —
  /// libgit2 only ever says "403".
  Future<List<String>> checkAccess(String repoFullName) async {
    final user = await client.get('https://api.github.com/user', options: _authOptions());
    final repo = await client.get(
      'https://api.github.com/repos/$repoFullName',
      options: _authOptions(),
    );
    final data = repo.data;
    final permissions = data is Map ? data['permissions'] : null;
    final push = permissions is Map ? permissions['push'] : null;
    return accessVerdictLines(
      repoFullName: repoFullName,
      userStatus: user.statusCode ?? 0,
      scopesHeader: user.headers.value('x-oauth-scopes'),
      repoStatus: repo.statusCode ?? 0,
      pushPermission: push is bool ? push : null,
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
