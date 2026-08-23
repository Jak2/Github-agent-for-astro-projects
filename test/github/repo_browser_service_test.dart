import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/github/github_repo.dart';
import 'package:git_agent_app/github/repo_browser_service.dart';
import 'package:git_agent_app/secrets/secret_store.dart';

class _FakeSecretStore implements SecretStore {
  final Map<String, String> _values;
  _FakeSecretStore(this._values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('repo_browser_service_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('throws NoGithubTokenException when no PAT is stored', () async {
    final secretStore = _FakeSecretStore({});
    expect(
      () => loadReposWithCloneStatus(secretStore: secretStore, reposRoot: tempDir),
      throwsA(isA<NoGithubTokenException>()),
    );
  });

  test('marks repos already cloned on disk and leaves others unmarked', () async {
    final secretStore = _FakeSecretStore({secretKeyGithubPat: 'token123'});
    final fakeRepos = [
      const GithubRepo(fullName: 'jak2/cloned-repo', cloneUrl: 'https://x/cloned', defaultBranch: 'main'),
      const GithubRepo(fullName: 'jak2/fresh-repo', cloneUrl: 'https://x/fresh', defaultBranch: 'main'),
    ];
    // Pre-create the "already cloned" repo's local directory using the same
    // naming scheme repoDirectory()/localCloneDirName() produce.
    await Directory('${tempDir.path}/jak2_cloned-repo').create(recursive: true);

    final result = await loadReposWithCloneStatus(
      secretStore: secretStore,
      reposRoot: tempDir,
      fetchRepos: (token) async {
        expect(token, 'token123');
        return fakeRepos;
      },
    );

    expect(result.repos, fakeRepos);
    expect(result.alreadyClonedFullNames, {'jak2/cloned-repo'});
  });

  test('propagates a fetch failure as-is', () async {
    final secretStore = _FakeSecretStore({secretKeyGithubPat: 'token123'});
    expect(
      () => loadReposWithCloneStatus(
        secretStore: secretStore,
        reposRoot: tempDir,
        fetchRepos: (token) async => throw StateError('network down'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
