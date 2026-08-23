# Repo-Aware General Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn git_agent_app's General Chat tab from a static stub into a real, LLM-backed assistant that lets the user browse/select a repo and file via tappable chat messages, answers structural questions from the file tree alone, reads a specific file's content only when explicitly asked, and hands off to the GitHub tab's existing structuring chat when the user wants to restructure a file.

**Architecture:** Three small new non-UI modules (`file_tree_text.dart`, `pending_file_handoff.dart`, `repo_browser_service.dart`) get built and unit-tested first, then `GeneralChatScreen` is rewritten to use them alongside the app's existing `buildEngine`/`RepoGitService`/`buildFileTree`, and finally `RootScreen` and `GithubTabScreen` get the small wiring changes needed to switch tabs and receive a handed-off file. The GitHub tab's existing repos→files→chat flow is otherwise untouched.

**Tech Stack:** Flutter/Dart, existing dependencies only (no new packages). Reuses `LlmEngine`/`buildEngine`, `RepoGitService`, `buildFileTree`, `SecretStore`, `EngineSettings`, the black/white theme helpers from `lib/theme/app_theme.dart`.

## Global Constraints

- Selection is tap-based only — no slash commands, no natural-language filename detection.
- Repo context sent to the LLM is tree-only (file/folder names and structure) until a specific file is explicitly opened via "Ask about this file" — never preload every file's content.
- "Ask about this file" reads the file once and keeps it in the conversation's context until a different file is opened; "Structure this file" hands off to the GitHub tab's existing chat sub-screen instead of duplicating it.
- The GitHub tab's own behavior, styling, and state machine are unchanged except for the one new "check for a pending handoff" hook.
- General Chat uses the same real-engine pattern as the rest of the app: `buildEngine(settings)` returning `null` blocks with a "configure an LLM in Config" message — no fake/placeholder engine.
- These are UI screens with no unit tests in this codebase (existing convention). The three new non-UI modules (`file_tree_text.dart`, `pending_file_handoff.dart`, `repo_browser_service.dart`) DO get unit tests since they live outside `lib/ui/`.
- The `flutter` command is not on PATH in the execution environment. Use the full path: `/home/asterisk/develop/flutter/bin/flutter`.

---

### Task 1: File tree text renderer

**Files:**
- Create: `lib/files/file_tree_text.dart`
- Test: `test/files/file_tree_text_test.dart`

**Interfaces:**
- Consumes: `FileTreeNode` (`lib/files/file_tree.dart`, already exists: `{name, relativePath, isDirectory, children}`).
- Produces: `String renderFileTreeAsText(FileTreeNode root)`.

- [ ] **Step 1: Write the failing tests**

```dart
// test/files/file_tree_text_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/files/file_tree.dart';
import 'package:git_agent_app/files/file_tree_text.dart';

FileTreeNode _file(String name, String relativePath) =>
    FileTreeNode(name: name, relativePath: relativePath, isDirectory: false, children: const []);

FileTreeNode _dir(String name, String relativePath, List<FileTreeNode> children) =>
    FileTreeNode(name: name, relativePath: relativePath, isDirectory: true, children: children);

void main() {
  test('renders a flat list of files with no indentation', () {
    final root = _dir('repo', '', [
      _file('README.md', 'README.md'),
      _file('config.dart', 'config.dart'),
    ]);
    final text = renderFileTreeAsText(root);
    expect(text, 'README.md\nconfig.dart\n');
  });

  test('renders nested directories with two-space indent per depth level', () {
    final root = _dir('repo', '', [
      _file('README.md', 'README.md'),
      _dir('docs', 'docs', [
        _dir('posts', 'docs/posts', []),
      ]),
      _dir('src', 'src', [
        _file('main.dart', 'src/main.dart'),
      ]),
    ]);
    final text = renderFileTreeAsText(root);
    expect(text, 'README.md\ndocs/\n  posts/\nsrc/\n  main.dart\n');
  });

  test('directories get a trailing slash, files do not', () {
    final root = _dir('repo', '', [_dir('lib', 'lib', []), _file('a.txt', 'a.txt')]);
    final text = renderFileTreeAsText(root);
    expect(text, contains('lib/\n'));
    expect(text, isNot(contains('a.txt/')));
  });

  test('an empty root produces an empty string', () {
    final root = _dir('repo', '', []);
    expect(renderFileTreeAsText(root), '');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/asterisk/develop/flutter/bin/flutter test test/files/file_tree_text_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/files/file_tree_text.dart'`

- [ ] **Step 3: Implement**

```dart
// lib/files/file_tree_text.dart
import 'file_tree.dart';

String renderFileTreeAsText(FileTreeNode root) {
  final buffer = StringBuffer();
  _renderChildren(root, 0, buffer);
  return buffer.toString();
}

void _renderChildren(FileTreeNode node, int depth, StringBuffer buffer) {
  for (final child in node.children) {
    buffer.writeln('${'  ' * depth}${child.name}${child.isDirectory ? '/' : ''}');
    if (child.isDirectory) {
      _renderChildren(child, depth + 1, buffer);
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/asterisk/develop/flutter/bin/flutter test test/files/file_tree_text_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/files/file_tree_text.dart test/files/file_tree_text_test.dart
git commit -m "feat: add file tree text renderer for LLM repo context"
```

---

### Task 2: Pending file handoff

**Files:**
- Create: `lib/chat/pending_file_handoff.dart`
- Test: `test/chat/pending_file_handoff_test.dart`

**Interfaces:**
- Consumes: `GithubRepo` (`lib/github/github_repo.dart`, already exists).
- Produces:
  ```dart
  typedef PendingFile = ({GithubRepo repo, Directory repoDir, String relativePath, String content});

  class PendingFileHandoff {
    PendingFileHandoff._();
    static final PendingFileHandoff instance = PendingFileHandoff._();
    void request({required GithubRepo repo, required Directory repoDir, required String relativePath, required String content});
    PendingFile? consume();
  }
  ```

- [ ] **Step 1: Write the failing tests**

```dart
// test/chat/pending_file_handoff_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/pending_file_handoff.dart';
import 'package:git_agent_app/github/github_repo.dart';

void main() {
  setUp(() {
    // Drain any leftover state from a previous test before each run,
    // since PendingFileHandoff.instance is a process-wide singleton.
    PendingFileHandoff.instance.consume();
  });

  test('consume returns null when nothing was requested', () {
    expect(PendingFileHandoff.instance.consume(), isNull);
  });

  test('consume returns the requested file exactly once', () {
    const repo = GithubRepo(fullName: 'jak2/repo', cloneUrl: 'https://x', defaultBranch: 'main');
    final dir = Directory('/tmp/repo');
    PendingFileHandoff.instance.request(
      repo: repo,
      repoDir: dir,
      relativePath: 'notes/idea.txt',
      content: 'raw notes',
    );

    final first = PendingFileHandoff.instance.consume();
    expect(first, isNotNull);
    expect(first!.repo.fullName, 'jak2/repo');
    expect(first.repoDir.path, '/tmp/repo');
    expect(first.relativePath, 'notes/idea.txt');
    expect(first.content, 'raw notes');

    expect(PendingFileHandoff.instance.consume(), isNull);
  });

  test('a second request overwrites an unconsumed first one', () {
    const repoA = GithubRepo(fullName: 'jak2/a', cloneUrl: 'https://a', defaultBranch: 'main');
    const repoB = GithubRepo(fullName: 'jak2/b', cloneUrl: 'https://b', defaultBranch: 'main');
    PendingFileHandoff.instance.request(
      repo: repoA,
      repoDir: Directory('/tmp/a'),
      relativePath: 'a.txt',
      content: 'a',
    );
    PendingFileHandoff.instance.request(
      repo: repoB,
      repoDir: Directory('/tmp/b'),
      relativePath: 'b.txt',
      content: 'b',
    );

    final result = PendingFileHandoff.instance.consume();
    expect(result!.repo.fullName, 'jak2/b');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/asterisk/develop/flutter/bin/flutter test test/chat/pending_file_handoff_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/chat/pending_file_handoff.dart'`

- [ ] **Step 3: Implement**

```dart
// lib/chat/pending_file_handoff.dart
import 'dart:io';
import '../github/github_repo.dart';

typedef PendingFile = ({GithubRepo repo, Directory repoDir, String relativePath, String content});

/// App-wide holder for a "please open this file in the structuring chat"
/// request. General Chat's "Structure this file" action calls [request],
/// then asks the root screen to switch to the GitHub tab; that tab calls
/// [consume] when it becomes visible again to pick up the request.
class PendingFileHandoff {
  PendingFileHandoff._();
  static final PendingFileHandoff instance = PendingFileHandoff._();

  PendingFile? _pending;

  void request({
    required GithubRepo repo,
    required Directory repoDir,
    required String relativePath,
    required String content,
  }) {
    _pending = (repo: repo, repoDir: repoDir, relativePath: relativePath, content: content);
  }

  /// Returns the pending request and clears it, or null if there isn't one.
  PendingFile? consume() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/asterisk/develop/flutter/bin/flutter test test/chat/pending_file_handoff_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/chat/pending_file_handoff.dart test/chat/pending_file_handoff_test.dart
git commit -m "feat: add PendingFileHandoff for chat-to-GitHub-tab file handoff"
```

---

### Task 3: Shared repo-listing service, and refactor GithubTabScreen to use it

**Files:**
- Create: `lib/github/repo_browser_service.dart`
- Test: `test/github/repo_browser_service_test.dart`
- Modify: `lib/ui/github_tab_screen.dart`

**Interfaces:**
- Consumes: `SecretStore`, `secretKeyGithubPat` (`lib/secrets/secret_store.dart`); `GithubApi`, `GithubRepo` (`lib/github/`); `repoDirectory` (`lib/git/repo_paths.dart`).
- Produces:
  ```dart
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
    Future<List<GithubRepo>> Function(String token)? fetchRepos, // injectable for tests
  });
  ```
  `fetchRepos` defaults to `(token) => GithubApi(client: Dio(), token: token).listRepos()` when omitted — tests inject a fake instead of hitting the network.

This task also removes the now-duplicated listing logic from `_GithubTabScreenState._loadRepos()`, replacing it with a call to this shared function — the only behavior-preserving refactor in this plan.

- [ ] **Step 1: Write the failing tests**

```dart
// test/github/repo_browser_service_test.dart
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/asterisk/develop/flutter/bin/flutter test test/github/repo_browser_service_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/github/repo_browser_service.dart'`

- [ ] **Step 3: Implement the service**

```dart
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `/home/asterisk/develop/flutter/bin/flutter test test/github/repo_browser_service_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Refactor `GithubTabScreen` to use the shared service**

In `lib/ui/github_tab_screen.dart`, replace the imports:

```dart
import 'package:dio/dio.dart';
```
and
```dart
import '../github/github_api.dart';
```
with:
```dart
import '../github/repo_browser_service.dart';
```

Replace the whole `_loadRepos()` method body:

```dart
  Future<void> _loadRepos() async {
    final reposRoot = await getApplicationDocumentsDirectory();
    try {
      final result = await loadReposWithCloneStatus(secretStore: widget.secretStore, reposRoot: reposRoot);
      if (!mounted) return;
      setState(() {
        _repos = result.repos;
        _reposRoot = reposRoot;
        _alreadyClonedFullNames = result.alreadyClonedFullNames;
      });
    } on NoGithubTokenException {
      if (mounted) setState(() => _reposError = 'Add a GitHub Personal Access Token in Config first.');
    } catch (e) {
      if (mounted) setState(() => _reposError = 'Failed to load repos: $e');
    }
  }
```

- [ ] **Step 6: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze lib/ui/github_tab_screen.dart lib/github/repo_browser_service.dart`
Expected: "No issues found!"

- [ ] **Step 7: Run the full test suite**

Run: `/home/asterisk/develop/flutter/bin/flutter test`
Expected: all existing tests plus the 3 new ones pass, no regressions.

- [ ] **Step 8: Commit**

```bash
git add lib/github/repo_browser_service.dart test/github/repo_browser_service_test.dart lib/ui/github_tab_screen.dart
git commit -m "feat: extract shared repo-listing service, refactor GithubTabScreen to use it"
```

---

### Task 4: GeneralChatScreen rewrite

**Files:**
- Modify: `lib/ui/general_chat_screen.dart` (full rewrite)

**Interfaces:**
- Consumes: `renderFileTreeAsText` (Task 1); `PendingFileHandoff` (Task 2); `loadReposWithCloneStatus`, `RepoListResult`, `NoGithubTokenException` (Task 3); `buildEngine` (`lib/engine/engine_factory.dart`); `LlmEngine` (`lib/engine/llm_engine.dart`); `RepoGitService` (`lib/git/repo_git_service.dart`); `repoDirectory` (`lib/git/repo_paths.dart`); `buildFileTree`, `FileTreeNode` (`lib/files/file_tree.dart`); `GithubRepo` (`lib/github/github_repo.dart`); `SecretStore`, `secretKeyGithubPat`, `secretKeyCloudApiKey` (`lib/secrets/secret_store.dart`); `EngineSettings` (`lib/settings/engine_settings.dart`); theme helpers (`lib/theme/app_theme.dart`).
- Produces: `class GeneralChatScreen extends StatefulWidget { final SecretStore secretStore; final void Function(int tabIndex) onSwitchTab; const GeneralChatScreen({super.key, required this.secretStore, required this.onSwitchTab}); }` — **breaking change** from the current `const GeneralChatScreen({super.key})` shape. `RootScreen`'s call site (Task 5) must be updated to match; until then, `flutter analyze` on the whole project will show an error there — expected at this point in the plan, resolved by Task 5.

No unit tests — matches this codebase's UI-screen convention (verified via `flutter analyze` here; manual on-device smoke test happens after Task 6).

- [ ] **Step 1: Replace the whole file**

```dart
// lib/ui/general_chat_screen.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chat/pending_file_handoff.dart';
import '../engine/engine_factory.dart';
import '../engine/llm_engine.dart';
import '../files/file_tree.dart';
import '../files/file_tree_text.dart';
import '../git/repo_git_service.dart';
import '../git/repo_paths.dart';
import '../github/github_repo.dart';
import '../github/repo_browser_service.dart';
import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';

sealed class _ChatItem {}

class _TextItem extends _ChatItem {
  final String text;
  final bool fromUser;
  _TextItem(this.text, {required this.fromUser});
}

class _RepoListItem extends _ChatItem {
  final List<GithubRepo> repos;
  final Set<String> alreadyClonedFullNames;
  _RepoListItem({required this.repos, required this.alreadyClonedFullNames});
}

class _FileListItem extends _ChatItem {
  final FileTreeNode root;
  _FileListItem(this.root);
}

class _FileActionsItem extends _ChatItem {
  final String relativePath;
  _FileActionsItem(this.relativePath);
}

class GeneralChatScreen extends StatefulWidget {
  final SecretStore secretStore;
  final void Function(int tabIndex) onSwitchTab;

  const GeneralChatScreen({super.key, required this.secretStore, required this.onSwitchTab});

  @override
  State<GeneralChatScreen> createState() => _GeneralChatScreenState();
}

class _GeneralChatScreenState extends State<GeneralChatScreen> {
  final List<_ChatItem> _items = [
    _TextItem(
      'Ask me anything about your repos. Tap the repo icon to browse and select one.',
      fromUser: false,
    ),
  ];
  final _inputController = TextEditingController();
  LlmEngine? _engine;
  bool _busy = false;

  GithubRepo? _activeRepo;
  Directory? _activeRepoDir;
  FileTreeNode? _fileTree;
  String? _openFilePath;
  String? _openFileContent;
  String? _cloningFullName;

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _initEngine() async {
    final prefs = await SharedPreferences.getInstance();
    var settings = await EngineSettings.load(prefs);
    final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';
    settings = settings.copyWith(cloudApiKey: apiKey);
    final engine = buildEngine(settings);
    if (!mounted) return;
    if (engine == null) {
      setState(() {
        _items.add(const _TextItem(
          'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
          fromUser: false,
        ));
      });
      return;
    }
    setState(() => _engine = engine);
  }

  Future<void> _browseRepos() async {
    setState(() => _busy = true);
    try {
      final reposRoot = await getApplicationDocumentsDirectory();
      final result = await loadReposWithCloneStatus(secretStore: widget.secretStore, reposRoot: reposRoot);
      if (!mounted) return;
      setState(() {
        _items.add(_RepoListItem(repos: result.repos, alreadyClonedFullNames: result.alreadyClonedFullNames));
      });
    } on NoGithubTokenException {
      if (mounted) {
        setState(() => _items.add(const _TextItem(
              'Add a GitHub Personal Access Token in Config first.',
              fromUser: false,
            )));
      }
    } catch (e) {
      if (mounted) setState(() => _items.add(_TextItem('Failed to load repos: $e', fromUser: false)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectRepo(GithubRepo repo, bool alreadyCloned) async {
    setState(() => _cloningFullName = alreadyCloned ? null : repo.fullName);
    try {
      final reposRoot = await getApplicationDocumentsDirectory();
      Directory dir;
      if (alreadyCloned) {
        dir = await repoDirectory(reposRoot, repo.fullName);
      } else {
        final token = await widget.secretStore.read(secretKeyGithubPat);
        if (token == null) {
          if (mounted) {
            setState(() => _items.add(const _TextItem(
                  'GitHub Personal Access Token missing. Add one in Config.',
                  fromUser: false,
                )));
          }
          return;
        }
        final service = RepoGitService(reposRoot: reposRoot);
        dir = await service.cloneRepo(repo: repo, token: token);
      }
      final tree = await buildFileTree(dir);
      if (!mounted) return;
      setState(() {
        _activeRepo = repo;
        _activeRepoDir = dir;
        _fileTree = tree;
        _openFilePath = null;
        _openFileContent = null;
        _items.add(_TextItem('Repo selected: ${repo.fullName}', fromUser: false));
      });
    } catch (e) {
      if (mounted) setState(() => _items.add(_TextItem('Failed to open repo: $e', fromUser: false)));
    } finally {
      if (mounted) setState(() => _cloningFullName = null);
    }
  }

  void _browseFiles() {
    final tree = _fileTree;
    if (tree == null) return;
    setState(() => _items.add(_FileListItem(tree)));
  }

  void _tapFile(String relativePath) {
    setState(() => _items.add(_FileActionsItem(relativePath)));
  }

  Future<void> _askAboutFile(String relativePath) async {
    final dir = _activeRepoDir;
    if (dir == null) return;
    try {
      final content = await File('${dir.path}/$relativePath').readAsString();
      if (!mounted) return;
      setState(() {
        _openFilePath = relativePath;
        _openFileContent = content;
        _items.add(_TextItem('Opened $relativePath — ask me anything about it.', fromUser: false));
      });
    } catch (e) {
      if (mounted) setState(() => _items.add(_TextItem('Could not read file: $e', fromUser: false)));
    }
  }

  Future<void> _structureFile(String relativePath) async {
    final repo = _activeRepo;
    final dir = _activeRepoDir;
    if (repo == null || dir == null) return;
    try {
      final content = await File('${dir.path}/$relativePath').readAsString();
      PendingFileHandoff.instance.request(
        repo: repo,
        repoDir: dir,
        relativePath: relativePath,
        content: content,
      );
      widget.onSwitchTab(1);
    } catch (e) {
      if (mounted) setState(() => _items.add(_TextItem('Could not read file: $e', fromUser: false)));
    }
  }

  String _buildPrompt() {
    final buffer = StringBuffer();
    final repo = _activeRepo;
    final tree = _fileTree;
    if (repo != null && tree != null) {
      buffer
        ..writeln('You are a helpful assistant answering questions about a GitHub repository.')
        ..writeln('Repository: ${repo.fullName}')
        ..writeln('File and folder structure:')
        ..writeln(renderFileTreeAsText(tree))
        ..writeln();
    }
    if (_openFilePath != null && _openFileContent != null) {
      buffer
        ..writeln('The user has opened this file for discussion:')
        ..writeln(_openFilePath)
        ..writeln('---')
        ..writeln(_openFileContent)
        ..writeln('---')
        ..writeln();
    }
    buffer.writeln('Conversation so far:');
    for (final item in _items) {
      if (item is _TextItem) {
        buffer.writeln('${item.fromUser ? "User" : "Assistant"}: ${item.text}');
      }
    }
    return buffer.toString();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() => _items.add(_TextItem(text, fromUser: true)));

    final engine = _engine;
    if (engine == null) {
      setState(() => _items.add(const _TextItem(
            'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
            fromUser: false,
          )));
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await engine.generate(_buildPrompt());
      if (mounted) setState(() => _items.add(_TextItem(result, fromUser: false)));
    } catch (e) {
      if (mounted) setState(() => _items.add(_TextItem('Generation failed: $e', fromUser: false)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Widget> _fileTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      tiles.add(InkWell(
        onTap: child.isDirectory ? null : () => _tapFile(child.relativePath),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12 + depth * 16.0, 8, 12, 8),
          child: Row(
            children: [
              Icon(
                child.isDirectory ? Icons.folder_outlined : Icons.description_outlined,
                size: 15,
                color: child.isDirectory ? AppColors.fg : AppColors.muted,
              ),
              const SizedBox(width: 8),
              Text(child.name, style: appMono(size: 12)),
            ],
          ),
        ),
      ));
      if (child.isDirectory) tiles.addAll(_fileTiles(child, depth + 1));
    }
    return tiles;
  }

  Widget _buildItem(_ChatItem item) {
    return switch (item) {
      _TextItem() => appChatBubble(text: item.text, fromUser: item.fromUser),
      _RepoListItem() => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.fg, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (final r in item.repos)
                InkWell(
                  onTap: _cloningFullName != null
                      ? null
                      : () => _selectRepo(r, item.alreadyClonedFullNames.contains(r.fullName)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        if (_cloningFullName == r.fullName)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg),
                          )
                        else
                          Icon(
                            item.alreadyClonedFullNames.contains(r.fullName) ? Icons.folder_open : Icons.download,
                            size: 16,
                            color: AppColors.fg,
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(r.fullName, style: appMono(size: 12.5), overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      _FileListItem() => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.fg, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(children: _fileTiles(item.root, 0)),
        ),
      _FileActionsItem() => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.fg, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.relativePath, style: appMono(size: 12.5, weight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: appSecondaryButton(
                      label: 'Ask about this file',
                      onPressed: () => _askAboutFile(item.relativePath),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: appSecondaryButton(
                      label: 'Structure this file',
                      onPressed: () => _structureFile(item.relativePath),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(child: Text('Assistant', style: appHeading(size: 17, weight: FontWeight.w700))),
                  appIconCircleButton(icon: Icons.hub_outlined, onPressed: _busy ? null : _browseRepos),
                  const SizedBox(width: 8),
                  appIconCircleButton(
                    icon: Icons.folder_outlined,
                    onPressed: (_busy || _activeRepo == null) ? null : _browseFiles,
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
            const Divider(color: AppColors.fg, thickness: 2, height: 2),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _items.length + (_busy ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _items.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: LinearProgressIndicator(color: AppColors.fg, backgroundColor: AppColors.divider),
                    );
                  }
                  return _buildItem(_items[index]);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: appBorderedField(
                      controller: _inputController,
                      hint: 'Ask about your repos...',
                    ),
                  ),
                  const SizedBox(width: 8),
                  appIconCircleButton(icon: Icons.arrow_forward, onPressed: _busy ? null : _send, filled: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze lib/ui/general_chat_screen.dart`
Expected: "No issues found!" (the whole-project analyze will show an error in `root_screen.dart` at this point — expected, resolved by Task 5).

- [ ] **Step 3: Commit**

```bash
git add lib/ui/general_chat_screen.dart
git commit -m "feat: rewrite GeneralChatScreen as a repo-aware assistant"
```

---

### Task 5: Wire RootScreen (secretStore + tab-switch callback)

**Files:**
- Modify: `lib/ui/root_screen.dart`

**Interfaces:**
- Consumes: `GeneralChatScreen({secretStore, onSwitchTab})` (Task 4).
- Produces: no new public API — `RootScreen`'s own constructor is unchanged.

- [ ] **Step 1: Update the tab construction**

In `lib/ui/root_screen.dart`, replace:

```dart
    final tabs = [
      const GeneralChatScreen(),
      GithubTabScreen(secretStore: widget.secretStore),
      ConfigScreen(secretStore: widget.secretStore),
    ];
```

with:

```dart
    final tabs = [
      GeneralChatScreen(
        secretStore: widget.secretStore,
        onSwitchTab: (index) => setState(() => _tabIndex = index),
      ),
      GithubTabScreen(secretStore: widget.secretStore),
      ConfigScreen(secretStore: widget.secretStore),
    ];
```

(Tab index 1 is GitHub, matching the `navItems` list order already in this file — General Chat's "Structure this file" action calls `onSwitchTab(1)`.)

- [ ] **Step 2: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze`
Expected: no errors (this resolves the expected error from Task 4). Pre-existing info-level deprecation notices are fine.

- [ ] **Step 3: Commit**

```bash
git add lib/ui/root_screen.dart
git commit -m "feat: wire GeneralChatScreen's tab-switch callback into RootScreen"
```

---

### Task 6: GithubTabScreen handoff-consumption hook

**Files:**
- Modify: `lib/ui/github_tab_screen.dart`

**Interfaces:**
- Consumes: `PendingFileHandoff` (Task 2).
- Produces: no new public API.

`IndexedStack` keeps `GithubTabScreen`'s `State` alive across tab switches — it is not recreated, so `initState` only runs once at app start. `RootScreen` rebuilding to switch `_tabIndex` (via `onSwitchTab`) causes `RootScreen.build()` to construct a new `GithubTabScreen(secretStore: ...)` widget instance every time, and because it has the same type and no key, Flutter calls `didUpdateWidget` on the existing State rather than recreating it — that is the reliable hook for detecting "this tab is being shown again, possibly because of a handoff."

- [ ] **Step 1: Add the import and the hook**

Add to the imports in `lib/ui/github_tab_screen.dart`:

```dart
import '../chat/pending_file_handoff.dart';
```

Add this method to `_GithubTabScreenState` (anywhere among the other methods — e.g. right after `_openFile`):

```dart
  void _consumePendingHandoffIfAny() {
    final pending = PendingFileHandoff.instance.consume();
    if (pending == null) return;
    setState(() {
      _activeRepo = pending.repo;
      _activeRepoDir = pending.repoDir;
      _activeFilePath = pending.relativePath;
      _activeFileContent = pending.content;
      _chatMessages.clear();
      _refinements.clear();
      _latestStructuredContent = null;
      _resolvedSavePath = null;
      _activePersonaSlug = null;
      _pendingSkillSlug = null;
      _onDeviceModelLoaded = false;
      _subScreen = _SubScreen.chat;
    });
    _initChat();
  }

  @override
  void didUpdateWidget(covariant GithubTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _consumePendingHandoffIfAny();
  }
```

Also call it once from `initState()`, in case a handoff is somehow already pending the very first time this tab builds (defensive — the normal path always goes through `didUpdateWidget` since `RootScreen` starts on tab index 0):

```dart
  @override
  void initState() {
    super.initState();
    _loadRepos();
    _consumePendingHandoffIfAny();
  }
```

- [ ] **Step 2: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze`
Expected: no errors, only the pre-existing info-level deprecation notices.

- [ ] **Step 3: Run the full test suite**

Run: `/home/asterisk/develop/flutter/bin/flutter test`
Expected: all existing tests plus this plan's 10 new tests (4 + 3 + 3) pass — 57 total, no regressions.

- [ ] **Step 4: Manual on-device smoke test**

Build and install per the existing device workflow (`bash android/gradlew assembleDebug` from `android/`, `adb install -r build/app/outputs/apk/debug/app-debug.apk`), then with a configured LLM engine and GitHub PAT confirm:
- Chat tab: tapping the repo icon shows a tappable repo list; selecting an already-cloned repo opens it immediately, selecting a not-yet-cloned one clones it first.
- After selecting a repo, tapping the folder icon shows the file tree as tappable rows.
- Tapping a file shows "Ask about this file" / "Structure this file".
- "Ask about this file" keeps the chat in place and a follow-up question about that file gets an answer referencing its content.
- "Structure this file" switches to the GitHub tab and lands directly in that file's structuring chat (not the repo list).
- Asking a structural question ("what files are in the repo") before opening any specific file gets an answer from the tree alone.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/github_tab_screen.dart
git commit -m "feat: consume pending file handoff when the GitHub tab becomes active"
```

## Post-plan: docs sync

After all 6 tasks are implemented and reviewed, update `docs/implementation.md`'s Change log with a summary entry for this feature (new modules, GeneralChatScreen rewrite, the didUpdateWidget handoff mechanism), and `docs/status_open_points.md` to move the repo-aware chat entry from "design approved, spec written" to "implemented."
