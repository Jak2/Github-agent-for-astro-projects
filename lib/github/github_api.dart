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

/// The GitHub account a token belongs to. Commits are authored as this
/// account, so [name] and [email] always resolve to something usable — GitHub
/// returns null for both on accounts that hide them.
class GithubUser {
  final String login;
  final String name;
  final String email;

  const GithubUser({required this.login, required this.name, required this.email});
}

/// Pure so the fallbacks can be tested without a network call.
///
/// A blank string is treated as absent: committing with an empty author name
/// or email produces a commit GitHub will not attribute to anyone.
GithubUser parseUserJson(Map<String, dynamic> json) {
  final login = json['login'];
  if (login is! String || login.trim().isEmpty) {
    throw StateError('GitHub returned an account with no login.');
  }

  String? textOrNull(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  final id = json['id'];
  // The address GitHub itself uses for accounts with a private email. Without
  // the numeric id it is still valid, just not linkable back to the account.
  final noreply = id == null
      ? '$login@users.noreply.github.com'
      : '$id+$login@users.noreply.github.com';

  return GithubUser(
    login: login,
    name: textOrNull(json['name']) ?? login,
    email: textOrNull(json['email']) ?? noreply,
  );
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

  /// Who this token belongs to. Doubles as token validation: Settings calls it
  /// before writing the PAT to the keystore.
  Future<GithubUser> currentUser() async {
    final response = await client.get(
      'https://api.github.com/user',
      options: _authOptions(),
    );
    final status = response.statusCode ?? 0;
    if (status != 200) {
      throw StateError('GitHub rejected the token (HTTP $status).');
    }
    final data = response.data;
    if (data is! Map) {
      throw StateError('GitHub returned an unexpected response for this token.');
    }
    return parseUserJson(Map<String, dynamic>.from(data));
  }

  /// Every repository the token can see.
  ///
  /// GitHub caps a page at 100. Stopping there would silently hide the rest of
  /// an account's repositories — including from the search box, which only
  /// filters what was fetched — so this walks pages until one comes back
  /// short. [maxPages] is a backstop against an endless loop, not a limit
  /// anyone is expected to hit.
  Future<List<GithubRepo>> listRepos({int maxPages = 10}) async {
    const perPage = 100;
    final all = <GithubRepo>[];
    for (var page = 1; page <= maxPages; page++) {
      final response = await client.get(
        'https://api.github.com/user/repos',
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
        }),
        queryParameters: {'per_page': perPage, 'sort': 'updated', 'page': page},
      );
      final batch = parseRepoListJson(response.data as List<dynamic>);
      all.addAll(batch);
      if (batch.length < perPage) break;
    }
    return all;
  }
}
