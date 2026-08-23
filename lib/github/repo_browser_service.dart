// lib/github/repo_browser_service.dart
import 'dart:io';
import 'package:dio/dio.dart';
import '../git/repo_paths.dart';
import '../secrets/secret_store.dart';
import 'github_api.dart';
import 'github_repo.dart';

class RepoListResult {
  final List<GithubRepo> repos;
  final Set<String> alreadyClonedFullNames;
  const RepoListResult({required this.repos, required this.alreadyClonedFullNames});
}

class NoGithubTokenException implements Exception {
  const NoGithubTokenException();
}

Future<RepoListResult> loadReposWithCloneStatus({
  required SecretStore secretStore,
  required Directory reposRoot,
  Future<List<GithubRepo>> Function(String token)? fetchRepos,
}) async {
  final token = await secretStore.read(secretKeyGithubPat);
  if (token == null || token.isEmpty) {
    throw const NoGithubTokenException();
  }
  final fetch = fetchRepos ?? ((t) => GithubApi(client: Dio(), token: t).listRepos());
  final repos = await fetch(token);

  final alreadyCloned = <String>{};
  for (final repo in repos) {
    final dir = await repoDirectory(reposRoot, repo.fullName);
    if (await dir.exists()) alreadyCloned.add(repo.fullName);
  }
  return RepoListResult(repos: repos, alreadyClonedFullNames: alreadyCloned);
}
