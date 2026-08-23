// lib/ui/repo_list_screen.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../git/repo_git_service.dart';
import '../git/repo_paths.dart';
import '../github/github_api.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import 'file_browser_screen.dart';

class RepoListScreen extends StatefulWidget {
  final SecretStore secretStore;
  const RepoListScreen({super.key, required this.secretStore});

  @override
  State<RepoListScreen> createState() => _RepoListScreenState();
}

class _RepoListScreenState extends State<RepoListScreen> {
  List<GithubRepo>? _repos;
  String? _error;
  String? _cloningFullName;
  Directory? _reposRoot;
  Set<String> _alreadyClonedFullNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null || token.isEmpty) {
      setState(() => _error = 'Add a GitHub Personal Access Token in Settings first.');
      return;
    }
    try {
      final api = GithubApi(client: Dio(), token: token);
      final repos = await api.listRepos();
      final reposRoot = await getApplicationDocumentsDirectory();
      final alreadyCloned = <String>{};
      for (final repo in repos) {
        final dir = await repoDirectory(reposRoot, repo.fullName);
        if (await dir.exists()) {
          alreadyCloned.add(repo.fullName);
        }
      }
      setState(() {
        _repos = repos;
        _reposRoot = reposRoot;
        _alreadyClonedFullNames = alreadyCloned;
      });
    } catch (e) {
      setState(() => _error = 'Failed to load repos: $e');
    }
  }

  void _openExisting(GithubRepo repo) {
    final reposRoot = _reposRoot;
    if (reposRoot == null) return;
    repoDirectory(reposRoot, repo.fullName).then((dir) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FileBrowserScreen(repo: repo, repoDir: dir, secretStore: widget.secretStore),
      ));
    });
  }

  Future<void> _clone(GithubRepo repo) async {
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('GitHub Personal Access Token missing. Add one in Settings.'),
        ));
      }
      return;
    }
    setState(() => _cloningFullName = repo.fullName);
    try {
      final reposRoot = await getApplicationDocumentsDirectory();
      final service = RepoGitService(reposRoot: reposRoot);
      final dir = await service.cloneRepo(repo: repo, token: token);
      if (!mounted) return;
      setState(() => _alreadyClonedFullNames = {..._alreadyClonedFullNames, repo.fullName});
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FileBrowserScreen(repo: repo, repoDir: dir, secretStore: widget.secretStore),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Clone failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _cloningFullName = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your repositories')),
      body: _error != null
          ? Center(child: Text(_error!))
          : _repos == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: _repos!.length,
                  itemBuilder: (context, index) {
                    final repo = _repos![index];
                    final isCloning = _cloningFullName == repo.fullName;
                    final isCloned = _alreadyClonedFullNames.contains(repo.fullName);
                    return ListTile(
                      title: Text(repo.fullName),
                      subtitle: isCloned ? const Text('Already cloned — tap to open') : null,
                      trailing: isCloning
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(isCloned ? Icons.folder_open : Icons.download),
                      onTap: _cloningFullName != null
                          ? null
                          : isCloned
                              ? () => _openExisting(repo)
                              : () => _clone(repo),
                    );
                  },
                ),
    );
  }
}
