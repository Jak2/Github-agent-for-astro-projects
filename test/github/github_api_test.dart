// test/github/github_api_test.dart
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
}
