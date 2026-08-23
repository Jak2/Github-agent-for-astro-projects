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

class GithubApi {
  final Dio client;
  final String token;

  GithubApi({required this.client, required this.token});

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
