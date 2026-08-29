# git_agent_app v1 (Clone → Structure → Push) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Flutter Android app that clones a GitHub repo, lets the user pick a file from it, restructures that file's content via an LLM (cloud or on-device) following bundled `structure.md` rules, lets the user refine the result via chat, then commits and pushes the result back to the repo at a user-chosen path.

**Architecture:** Layered Dart packages under `lib/`: `settings` (persisted config), `engine` (LLM abstraction: cloud API / on-device gguf), `github` (REST API for repo listing), `secrets` (encrypted token storage), `git` (clone/commit/push via `git2dart`, FFI bindings to libgit2), `files` (local file tree), `chat` (prompt building + save-path resolution — the two units with real logic to unit test), and `ui` (four screens: Settings, Repo List, File Browser, Chat). Business logic is kept in plain Dart classes/functions so it's testable without widget tests; screens are thin and manually verified via `flutter run`.

**Tech Stack:** Flutter 3.47.0 / Dart 3.13.0 (at `/home/asterisk/develop/flutter/bin`), `dio` (HTTP), `git2dart` + `git2dart_binaries` (FFI bindings to libgit2 with prebuilt native libraries — see Task 8 for why this replaced two prior pure-Dart choices), `flutter_secure_storage` (PAT storage), `shared_preferences` (non-secret settings), `file_picker` (import structure.md / pick on-device model file), `share_plus` (export structure.md), `path_provider` (internal storage root), `llama_cpp_dart ^0.0.9` (on-device inference — older than `voice_notes_app`'s `^0.2.2` pin because `^0.2.2`'s `image`→`archive ^4.0.2+` chain conflicted with the originally-planned `git_on_dart`'s `archive ^3.4.0`; `^0.0.9` exposes the same `LlamaParent` isolate API and resolves cleanly — this pin stays even after dropping `git_on_dart`, no reason to churn it back).

## Global Constraints

- Dart SDK: `^3.13.0` (copy from spec's tech stack / matches installed toolchain).
- Android only for v1 — no iOS/web target work.
- PAT and any cloud API key must go through `flutter_secure_storage`; never `print`/`log` them, never include raw key values in exception messages surfaced to the UI.
- No fake/placeholder LLM engine fallback: if the engine can't be built from current settings, `buildEngine` returns `null` and the chat screen must block with a "configure LLM in Settings" message — never silently fabricate structured output (spec: Data flow & error handling).
- Chat conversation state is in-memory only, cleared on screen exit — no persistence across sessions (spec: Data flow & error handling; Explicitly out of scope).
- Save path for the pushed file is always user-directed (explicit picked folder, or parsed from a chat instruction) — never auto-guessed from the source file name (spec: Screens §4, Decision #10).
- Every pure-logic unit (settings parsing, JSON parsing, path resolution, prompt building) gets a real `flutter_test`/`test` unit test with assertions — no widget tests required for v1 (spec: Testing).

---

## File Structure

```
my_learning_projects/git_agent_app/
  pubspec.yaml
  assets/
    structure.md                      # bundled default structuring rules
  lib/
    main.dart
    settings/
      engine_settings.dart            # EngineChoice, EngineSettings (load/save via SharedPreferences)
    engine/
      llm_engine.dart                 # LlmEngine interface
      cloud_api_engine.dart           # CloudApiEngine implements LlmEngine
      on_device_llama_engine.dart     # OnDeviceLlamaEngine implements LlmEngine
      engine_factory.dart             # buildEngine(EngineSettings) -> LlmEngine?
    secrets/
      secret_store.dart               # SecretStore interface + SecureSecretStore impl
    github/
      github_repo.dart                # GithubRepo model
      github_api.dart                 # parseRepoListJson (pure) + GithubApi.listRepos()
    git/
      repo_paths.dart                 # localCloneDirName (pure) + repoDirectory()
      repo_git_service.dart           # RepoGitService: cloneRepo / commitAndPush via git2dart
    files/
      file_tree.dart                  # FileTreeNode + buildFileTree(Directory)
    chat/
      save_path_resolver.dart         # resolveSavePath (pure, unit-tested per spec)
      structuring_prompt.dart         # buildStructuringPrompt (pure)
    ui/
      settings_screen.dart
      repo_list_screen.dart
      file_browser_screen.dart
      chat_screen.dart
  test/
    settings/engine_settings_test.dart
    engine/engine_factory_test.dart
    engine/cloud_api_engine_test.dart
    github/github_api_test.dart
    git/repo_paths_test.dart
    files/file_tree_test.dart
    chat/save_path_resolver_test.dart
    chat/structuring_prompt_test.dart
```

## Interfaces Reference (exact signatures used across tasks)

```dart
// settings/engine_settings.dart
enum EngineChoice { cloud, onDevice }
class EngineSettings {
  final EngineChoice choice;
  final String cloudEndpoint, cloudApiKey, cloudModel, cloudHeaders, onDeviceModelPath;
  Map<String, String> get cloudHeadersMap;
  static Future<EngineSettings> load(SharedPreferences prefs);
  Future<void> save(SharedPreferences prefs);
}

// engine/llm_engine.dart
abstract class LlmEngine {
  Future<String> generate(String prompt);
}

// engine/engine_factory.dart
LlmEngine? buildEngine(EngineSettings settings);

// secrets/secret_store.dart
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}
const secretKeyGithubPat = 'github_pat';

// github/github_repo.dart
class GithubRepo {
  final String fullName, cloneUrl, defaultBranch;
}

// github/github_api.dart
List<GithubRepo> parseRepoListJson(List<dynamic> json);
class GithubApi {
  Future<List<GithubRepo>> listRepos();
}

// git/repo_paths.dart
String localCloneDirName(String fullName);
Future<Directory> repoDirectory(Directory reposRoot, String fullName);

// git/repo_git_service.dart
class RepoGitService {
  Future<Directory> cloneRepo({required GithubRepo repo, required String token});
  Future<void> commitAndPush({
    required Directory repoDir,
    required String relativeFilePath,
    required String content,
    required String commitMessage,
    required String token,
  });
}

// files/file_tree.dart
class FileTreeNode {
  final String name, relativePath;
  final bool isDirectory;
  final List<FileTreeNode> children;
}
Future<FileTreeNode> buildFileTree(Directory root);

// chat/save_path_resolver.dart
String? resolveSavePath({required String instruction, required String sourceRelativePath});

// chat/structuring_prompt.dart
String buildStructuringPrompt({
  required String structureRules,
  required String sourceContent,
  required List<String> refinementRequests,
});
```

---

### Task 1: Project scaffold

**Files:**
- Create: `my_learning_projects/git_agent_app/pubspec.yaml`
- Create: `my_learning_projects/git_agent_app/assets/structure.md`
- Create: `my_learning_projects/git_agent_app/.gitignore` (Flutter default)
- Create: `my_learning_projects/git_agent_app/lib/main.dart` (placeholder `MaterialApp` with empty `Scaffold`)

**Interfaces:**
- Produces: a runnable Flutter project skeleton every later task builds inside.

- [ ] **Step 1: Generate the Flutter project**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects
flutter create --platforms=android --org com.jayaarunkumar --project-name git_agent_app git_agent_app
```

- [ ] **Step 2: Replace generated `pubspec.yaml` dependencies**

Open `git_agent_app/pubspec.yaml` and set the `dependencies:` block to:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  dio: ^5.7.0
  git_on_dart: ^0.1.4
  flutter_secure_storage: ^9.2.2
  shared_preferences: ^2.3.0
  file_picker: ^10.0.0
  share_plus: ^10.0.0
  path_provider: ^2.1.0
  path: ^1.9.0
  llama_cpp_dart: ^0.0.9
```

`llama_cpp_dart ^0.2.2` (matching `voice_notes_app`) conflicted with the originally
planned `git_on_dart`'s `archive ^3.4.0` pin via the `image` package's `archive ^4.0.2+`
requirement — version solving failed. `^0.0.9` was pub's own suggested resolution and is
confirmed to expose the same `LlamaParent`/`LlamaLoad`/`ModelParams`/`ContextParams`/
`SamplerParams` isolate API used in Task 3, so no code changes were needed there. Note:
`git_on_dart` itself was later dropped entirely (Task 8 found its HTTPS clone/push are
non-functional stubs) in favor of `git2dart`, but the `llama_cpp_dart` pin stays at
`^0.0.9` — no reason to bump it back since it works and nothing depends on `^0.2.2`
specifically.

Add an `assets:` entry under the `flutter:` section:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/structure.md
```

- [ ] **Step 3: Write the bundled default `structure.md`**

Create `git_agent_app/assets/structure.md`:

```markdown
# Structuring Rules

You are given raw source content. Reformat it into clean Markdown following
these rules:

1. Add a single H1 title summarizing the content.
2. Break the body into H2 sections by topic.
3. Convert any list-like prose into Markdown bullet or numbered lists.
4. Preserve all factual content and code blocks verbatim — do not summarize
   away detail, only reorganize and reformat.
5. Do not invent content that isn't present in the source.
6. Output ONLY the final Markdown document — no commentary, no explanation
   of what you changed.
```

- [ ] **Step 4: Fetch dependencies**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter pub get
```

Expected: completes with `Got dependencies!` and no version solving errors.

- [ ] **Step 5: Commit**

```bash
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
git add -A
git commit -m "chore: scaffold git_agent_app Flutter project"
```

---

### Task 2: EngineSettings (persisted LLM configuration)

**Files:**
- Create: `lib/settings/engine_settings.dart`
- Test: `test/settings/engine_settings_test.dart`

**Interfaces:**
- Produces: `EngineChoice`, `EngineSettings` exactly as in the Interfaces Reference. Task 4 (`engine_factory.dart`) and all UI tasks consume this.

- [ ] **Step 1: Write the failing test**

```dart
// test/settings/engine_settings_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:git_agent_app/settings/engine_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load returns cloud defaults when nothing saved', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    expect(settings.choice, EngineChoice.cloud);
    expect(settings.cloudEndpoint, '');
    expect(settings.onDeviceModelPath, '');
  });

  test('save then load round-trips all fields', () async {
    final prefs = await SharedPreferences.getInstance();
    const settings = EngineSettings(
      choice: EngineChoice.onDevice,
      cloudEndpoint: 'https://api.example.com/v1/chat',
      cloudApiKey: 'sk-test',
      cloudModel: 'gpt-x',
      cloudHeaders: 'X-Org: acme',
      onDeviceModelPath: '/sdcard/models/model.gguf',
    );
    await settings.save(prefs);

    final loaded = await EngineSettings.load(prefs);
    expect(loaded.choice, EngineChoice.onDevice);
    expect(loaded.cloudEndpoint, 'https://api.example.com/v1/chat');
    expect(loaded.cloudApiKey, 'sk-test');
    expect(loaded.cloudModel, 'gpt-x');
    expect(loaded.cloudHeaders, 'X-Org: acme');
    expect(loaded.onDeviceModelPath, '/sdcard/models/model.gguf');
  });

  test('cloudHeadersMap parses "Name: value" lines and skips malformed ones', () {
    const settings = EngineSettings(
      cloudHeaders: 'X-Org: acme\nbad-line-no-colon\nX-Env:  staging  ',
    );
    expect(settings.cloudHeadersMap, {
      'X-Org': 'acme',
      'X-Env': 'staging',
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/settings/engine_settings_test.dart
```

Expected: FAIL — `lib/settings/engine_settings.dart` doesn't exist yet (import error).

- [ ] **Step 3: Write the implementation**

```dart
// lib/settings/engine_settings.dart
import 'package:shared_preferences/shared_preferences.dart';

enum EngineChoice { cloud, onDevice }

class EngineSettings {
  final EngineChoice choice;
  final String cloudEndpoint;
  final String cloudApiKey;
  final String cloudModel;
  final String cloudHeaders; // raw "Header: value" lines, one per line
  final String onDeviceModelPath;

  const EngineSettings({
    this.choice = EngineChoice.cloud,
    this.cloudEndpoint = '',
    this.cloudApiKey = '',
    this.cloudModel = '',
    this.cloudHeaders = '',
    this.onDeviceModelPath = '',
  });

  EngineSettings copyWith({
    EngineChoice? choice,
    String? cloudEndpoint,
    String? cloudApiKey,
    String? cloudModel,
    String? cloudHeaders,
    String? onDeviceModelPath,
  }) {
    return EngineSettings(
      choice: choice ?? this.choice,
      cloudEndpoint: cloudEndpoint ?? this.cloudEndpoint,
      cloudApiKey: cloudApiKey ?? this.cloudApiKey,
      cloudModel: cloudModel ?? this.cloudModel,
      cloudHeaders: cloudHeaders ?? this.cloudHeaders,
      onDeviceModelPath: onDeviceModelPath ?? this.onDeviceModelPath,
    );
  }

  Map<String, String> get cloudHeadersMap {
    final map = <String, String>{};
    for (final line in cloudHeaders.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
    return map;
  }

  static const _keyChoice = 'engine_choice';
  static const _keyEndpoint = 'cloud_endpoint';
  static const _keyApiKey = 'cloud_api_key';
  static const _keyModel = 'cloud_model';
  static const _keyHeaders = 'cloud_headers';
  static const _keyModelPath = 'on_device_model_path';

  static Future<EngineSettings> load(SharedPreferences prefs) async {
    return EngineSettings(
      choice: EngineChoice.values.firstWhere(
        (c) => c.name == prefs.getString(_keyChoice),
        orElse: () => EngineChoice.cloud,
      ),
      cloudEndpoint: prefs.getString(_keyEndpoint) ?? '',
      cloudApiKey: prefs.getString(_keyApiKey) ?? '',
      cloudModel: prefs.getString(_keyModel) ?? '',
      cloudHeaders: prefs.getString(_keyHeaders) ?? '',
      onDeviceModelPath: prefs.getString(_keyModelPath) ?? '',
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(_keyChoice, choice.name);
    await prefs.setString(_keyEndpoint, cloudEndpoint);
    await prefs.setString(_keyApiKey, cloudApiKey);
    await prefs.setString(_keyModel, cloudModel);
    await prefs.setString(_keyHeaders, cloudHeaders);
    await prefs.setString(_keyModelPath, onDeviceModelPath);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/settings/engine_settings_test.dart
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/settings/engine_settings.dart test/settings/engine_settings_test.dart
git commit -m "feat: add persisted EngineSettings"
```

---

### Task 3: LlmEngine implementations (cloud + on-device)

**Files:**
- Create: `lib/engine/llm_engine.dart`
- Create: `lib/engine/cloud_api_engine.dart`
- Create: `lib/engine/on_device_llama_engine.dart`
- Test: `test/engine/cloud_api_engine_test.dart`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `LlmEngine` (abstract), `CloudApiEngine`, `OnDeviceLlamaEngine` — consumed by Task 4's `buildEngine`.

- [ ] **Step 1: Write the failing test**

```dart
// test/engine/cloud_api_engine_test.dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/engine/cloud_api_engine.dart';

void main() {
  test('generate posts prompt and returns content field', () async {
    final dio = Dio();
    dio.httpClientAdapter = _FakeAdapter((options) {
      expect(options.headers['Authorization'], 'Bearer test-key');
      expect(options.data, {'prompt': 'hello', 'model': 'test-model'});
      return ResponseBody.fromString(
        '{"content": "structured output"}',
        200,
        headers: {'content-type': ['application/json']},
      );
    });
    final engine = CloudApiEngine(
      client: dio,
      apiKey: 'test-key',
      endpoint: 'https://example.com/generate',
      model: 'test-model',
    );

    final result = await engine.generate('hello');

    expect(result, 'structured output');
  });

  test('generate throws when response has no content field', () async {
    final dio = Dio();
    dio.httpClientAdapter = _FakeAdapter((options) {
      return ResponseBody.fromString('{"unexpected": true}', 200,
          headers: {'content-type': ['application/json']});
    });
    final engine = CloudApiEngine(
      client: dio,
      apiKey: 'test-key',
      endpoint: 'https://example.com/generate',
    );

    expect(() => engine.generate('hello'), throwsA(isA<DioException>()));
  });
}

class _FakeAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) handler;
  _FakeAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream,
      Future<void>? cancelFuture) async {
    return handler(options);
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/engine/cloud_api_engine_test.dart
```

Expected: FAIL — `lib/engine/cloud_api_engine.dart` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```dart
// lib/engine/llm_engine.dart
abstract class LlmEngine {
  Future<String> generate(String prompt);
}
```

```dart
// lib/engine/cloud_api_engine.dart
import 'package:dio/dio.dart';
import 'llm_engine.dart';

class CloudApiEngine implements LlmEngine {
  final Dio client;
  final String apiKey;
  final String endpoint;
  final String model;
  final Map<String, String> extraHeaders;

  CloudApiEngine({
    required this.client,
    required this.apiKey,
    required this.endpoint,
    this.model = '',
    this.extraHeaders = const {},
  });

  @override
  Future<String> generate(String prompt) async {
    final response = await client.post(
      endpoint,
      options: Options(headers: {'Authorization': 'Bearer $apiKey', ...extraHeaders}),
      data: {'prompt': prompt, if (model.isNotEmpty) 'model': model},
    );
    final data = response.data;
    if (data is! Map || data['content'] is! String) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'Unexpected response shape from cloud LLM endpoint',
      );
    }
    return data['content'] as String;
  }
}
```

```dart
// lib/engine/on_device_llama_engine.dart
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'llm_engine.dart';

/// On-device engine backed by llama_cpp_dart's isolate-based LlamaParent.
/// The package already runs inference in a child isolate, so this class
/// just drives its prompt/stream API.
class OnDeviceLlamaEngine implements LlmEngine {
  final String modelPath;
  LlamaParent? _parent;

  OnDeviceLlamaEngine({required this.modelPath});

  Future<LlamaParent> _ensureLoaded() async {
    if (_parent != null) return _parent!;
    final parent = LlamaParent(
      LlamaLoad(
        path: modelPath,
        modelParams: ModelParams(),
        contextParams: ContextParams(),
        samplingParams: SamplerParams(),
      ),
    );
    await parent.init();
    _parent = parent;
    return parent;
  }

  @override
  Future<String> generate(String prompt) async {
    final parent = await _ensureLoaded();
    final buffer = StringBuffer();
    final sub = parent.stream.listen(buffer.write);
    try {
      final promptId = await parent.sendPrompt(prompt);
      await parent.completions
          .firstWhere((event) => event.promptId == promptId)
          .timeout(const Duration(seconds: 120));
    } finally {
      await sub.cancel();
    }
    return buffer.toString();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/engine/cloud_api_engine_test.dart
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engine/llm_engine.dart lib/engine/cloud_api_engine.dart lib/engine/on_device_llama_engine.dart test/engine/cloud_api_engine_test.dart
git commit -m "feat: add cloud and on-device LlmEngine implementations"
```

---

### Task 4: EngineFactory (no fake fallback)

**Files:**
- Create: `lib/engine/engine_factory.dart`
- Test: `test/engine/engine_factory_test.dart`

**Interfaces:**
- Consumes: `EngineSettings` (Task 2), `LlmEngine`/`CloudApiEngine`/`OnDeviceLlamaEngine` (Task 3).
- Produces: `LlmEngine? buildEngine(EngineSettings settings)` — consumed by the chat screen (Task 12).

- [ ] **Step 1: Write the failing test**

```dart
// test/engine/engine_factory_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/engine/cloud_api_engine.dart';
import 'package:git_agent_app/engine/on_device_llama_engine.dart';
import 'package:git_agent_app/engine/engine_factory.dart';
import 'package:git_agent_app/settings/engine_settings.dart';

void main() {
  test('returns null for cloud choice with empty endpoint or key', () {
    expect(buildEngine(const EngineSettings(choice: EngineChoice.cloud)), isNull);
    expect(
      buildEngine(const EngineSettings(
        choice: EngineChoice.cloud,
        cloudEndpoint: 'https://x.com',
      )),
      isNull,
    );
  });

  test('returns CloudApiEngine when cloud settings are complete', () {
    final engine = buildEngine(const EngineSettings(
      choice: EngineChoice.cloud,
      cloudEndpoint: 'https://x.com',
      cloudApiKey: 'key',
    ));
    expect(engine, isA<CloudApiEngine>());
  });

  test('returns null for onDevice choice with empty model path', () {
    expect(buildEngine(const EngineSettings(choice: EngineChoice.onDevice)), isNull);
  });

  test('returns OnDeviceLlamaEngine when model path is set', () {
    final engine = buildEngine(const EngineSettings(
      choice: EngineChoice.onDevice,
      onDeviceModelPath: '/sdcard/models/model.gguf',
    ));
    expect(engine, isA<OnDeviceLlamaEngine>());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/engine/engine_factory_test.dart
```

Expected: FAIL — `lib/engine/engine_factory.dart` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```dart
// lib/engine/engine_factory.dart
import 'package:dio/dio.dart';
import '../settings/engine_settings.dart';
import 'cloud_api_engine.dart';
import 'llm_engine.dart';
import 'on_device_llama_engine.dart';

/// Returns null when [settings] doesn't have enough configured to build a
/// real engine. Callers must treat null as "block and ask the user to
/// configure the LLM in Settings" — never substitute a fake/placeholder
/// engine, since that risks pushing fabricated content to a real repo.
LlmEngine? buildEngine(EngineSettings settings) {
  switch (settings.choice) {
    case EngineChoice.cloud:
      if (settings.cloudEndpoint.isEmpty || settings.cloudApiKey.isEmpty) {
        return null;
      }
      return CloudApiEngine(
        client: Dio(),
        apiKey: settings.cloudApiKey,
        endpoint: settings.cloudEndpoint,
        model: settings.cloudModel,
        extraHeaders: settings.cloudHeadersMap,
      );
    case EngineChoice.onDevice:
      if (settings.onDeviceModelPath.isEmpty) return null;
      return OnDeviceLlamaEngine(modelPath: settings.onDeviceModelPath);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/engine/engine_factory_test.dart
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engine/engine_factory.dart test/engine/engine_factory_test.dart
git commit -m "feat: add EngineFactory with no fake-engine fallback"
```

---

### Task 5: SecretStore (encrypted PAT storage)

**Files:**
- Create: `lib/secrets/secret_store.dart`

**Interfaces:**
- Produces: `SecretStore` interface, `SecureSecretStore` impl, `secretKeyGithubPat` constant — consumed by Settings screen (Task 11) and `GithubApi`/`RepoGitService` callers.

- [ ] **Step 1: Write the implementation**

`flutter_secure_storage` talks to a platform channel, which isn't available under
plain `flutter test` without channel mocking — not worth it for a 15-line wrapper.
Keep the interface abstract so a fake can be swapped in wherever it's consumed
(Tasks 11 and 12 use the interface type, not the concrete class, in their own
constructors), and verify the real implementation manually in Task 15's end-to-end
smoke test instead.

```dart
// lib/secrets/secret_store.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const secretKeyGithubPat = 'github_pat';

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureSecretStore implements SecretStore {
  final FlutterSecureStorage _storage;

  SecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
}
```

- [ ] **Step 2: Verify it compiles**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter analyze lib/secrets/secret_store.dart
```

Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/secrets/secret_store.dart
git commit -m "feat: add SecretStore abstraction for encrypted PAT storage"
```

---

### Task 6: GitHub repo listing

**Files:**
- Create: `lib/github/github_repo.dart`
- Create: `lib/github/github_api.dart`
- Test: `test/github/github_api_test.dart`

**Interfaces:**
- Consumes: `SecretStore` (Task 5) for the PAT, at the call site (Task 12 constructs `GithubApi` with a token string already read from `SecretStore`).
- Produces: `GithubRepo`, `parseRepoListJson`, `GithubApi` — consumed by Repo List screen (Task 12) and `RepoGitService` (Task 8, via `GithubRepo.cloneUrl`).

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/github/github_api_test.dart
```

Expected: FAIL — `lib/github/github_api.dart` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```dart
// lib/github/github_repo.dart
class GithubRepo {
  final String fullName;
  final String cloneUrl;
  final String defaultBranch;

  const GithubRepo({
    required this.fullName,
    required this.cloneUrl,
    required this.defaultBranch,
  });
}
```

```dart
// lib/github/github_api.dart
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/github/github_api_test.dart
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/github/github_repo.dart lib/github/github_api.dart test/github/github_api_test.dart
git commit -m "feat: add GitHub repo listing API client"
```

---

### Task 7: Repo local storage paths

**Files:**
- Create: `lib/git/repo_paths.dart`
- Test: `test/git/repo_paths_test.dart`

**Interfaces:**
- Produces: `localCloneDirName`, `repoDirectory` — consumed by `RepoGitService` (Task 8).

- [ ] **Step 1: Write the failing test**

```dart
// test/git/repo_paths_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/git/repo_paths.dart';

void main() {
  test('localCloneDirName replaces slashes with underscores', () {
    expect(localCloneDirName('jak2/git_agent_app'), 'jak2_git_agent_app');
  });

  test('repoDirectory returns a directory under reposRoot named by localCloneDirName', () async {
    final tempRoot = await Directory.systemTemp.createTemp('repos_root_test');
    addTearDown(() => tempRoot.delete(recursive: true));

    final dir = await repoDirectory(tempRoot, 'jak2/git_agent_app');

    expect(dir.path, '${tempRoot.path}/jak2_git_agent_app');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/git/repo_paths_test.dart
```

Expected: FAIL — `lib/git/repo_paths.dart` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```dart
// lib/git/repo_paths.dart
import 'dart:io';
import 'package:path/path.dart' as p;

String localCloneDirName(String fullName) => fullName.replaceAll('/', '_');

Future<Directory> repoDirectory(Directory reposRoot, String fullName) async {
  return Directory(p.join(reposRoot.path, localCloneDirName(fullName)));
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/git/repo_paths_test.dart
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/git/repo_paths.dart test/git/repo_paths_test.dart
git commit -m "feat: add repo local storage path resolution"
```

---

### Task 8: RepoGitService (clone / commit / push via git2dart)

**Files:**
- Modify: `pubspec.yaml` (remove `git_on_dart`, add `git2dart` + `git2dart_binaries`)
- Create: `lib/git/repo_git_service.dart`

**Interfaces:**
- Consumes: `GithubRepo` (Task 6), `repoDirectory` (Task 7).
- Produces: `RepoGitService` — consumed by Repo List screen (Task 12, clone) and Chat screen (Task 14, commit+push).

**Library history for this task:** the plan originally specified `dart_git` (found
abandoned before Task 1), then `git_on_dart` (Task 1 scaffolded with it — v0.1.4,
looked active). Task 8's own investigation found `git_on_dart`'s HTTPS clone/push are
non-functional stubs: its own source comments admit packfile transfer "would need pack
protocol" / "not implemented" — clone never writes git objects, and push sends a body
GitHub's `git-receive-pack` endpoint cannot parse as pkt-line+packfile. That is a
correctness-fatal gap for this app's core requirement, not a naming mismatch. Human
decision: replace with `git2dart` (v0.5.4, published ~32 days before this plan), FFI
bindings to the real libgit2 C library, with prebuilt native libraries supplied by the
companion `git2dart_binaries` package (no manual NDK/CMake setup required).

**This task's exact code is NOT pre-written in this brief** — unlike other tasks, the
implementer must research git2dart's real exported API before writing
`repo_git_service.dart`, the same way Task 8's first attempt correctly refused to trust
`git_on_dart`'s README-derived guesses. Do not invent method signatures from memory or
from pub.dev's rendered doc summaries alone — read the installed package's actual
source.

- [ ] **Step 1: Swap the dependency**

Edit `pubspec.yaml`: remove the `git_on_dart: ^0.1.4` line, add:

```yaml
  git2dart: ^0.5.4
  git2dart_binaries: ^1.12.1
```

Run:

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter pub get
```

Expected: resolves cleanly (report the exact resolved versions if pub picks something
other than the pins above — adjust the pins to match rather than fighting the solver).

- [ ] **Step 2: Research the real git2dart API**

Read the installed package source directly, don't rely on memory or a summarized doc
page:

```bash
find ~/.pub-cache/hosted/pub.dev/git2dart-*/lib -name "*.dart" | xargs grep -l "class Repository\|class Remote\|class Signature\|class Index\|Callbacks\|Credentials" 
```

Read enough of those files (and `git2dart_binaries`' README for the mandatory
`PlatformSpecific.initialize()` mobile init call, if it exists) to answer, with exact
signatures quoted from source:

1. How to clone an HTTPS URL with token/username-password credentials into a local
   path (`Repository.clone(...)` — confirm the real parameter names and how
   credentials/callbacks are supplied for HTTPS auth specifically, not just SSH).
2. How to stage a file and create a commit with an author (there's a
   `createCommitOnHead` extension method per the pub.dev docs — confirm its real
   signature, or find the equivalent Index/Tree/Commit primitives if that doesn't fit).
3. How to push a branch to a remote over HTTPS with the same token credentials (this is
   the part `git_on_dart` got wrong — find git2dart's actual `Remote`/push API and
   confirm from source, not assumption, that it performs a real smart-HTTP
   pkt-line+packfile push, e.g. by finding where it calls into libgit2's
   `git_remote_push` via FFI rather than hand-rolling protocol bytes in Dart).

- [ ] **Step 3: Write the implementation**

Write `lib/git/repo_git_service.dart` with this exact public API (callers in later
tasks depend on these names):

```dart
class RepoGitService {
  final Directory reposRoot;

  RepoGitService({required this.reposRoot});

  Future<Directory> cloneRepo({required GithubRepo repo, required String token}) async {
    // ... real git2dart clone call, using repoDirectory(reposRoot, repo.fullName)
    // from repo_paths.dart as the local path, HTTPS token credentials from git2dart's
    // real credentials/callbacks API.
  }

  Future<void> commitAndPush({
    required Directory repoDir,
    required String relativeFilePath,
    required String content,
    required String commitMessage,
    required String token,
  }) async {
    // ... write the file, stage it, commit with an author, push to origin over HTTPS
    // using the real git2dart API found in Step 2.
  }
}
```

Internals are the implementer's judgment based on the real API found in Step 2 — the
two method signatures above (names, parameter names, types) are the fixed contract.

- [ ] **Step 4: Verify it compiles**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter analyze lib/git/repo_git_service.dart
```

Expected: `No issues found!`

- [ ] **Step 5: Manual smoke test against a real throwaway repo**

Create a scratch **private** GitHub repo (e.g. `git-agent-app-smoke-test`) with one
file in it, generate a PAT with `repo` scope, then run a throwaway script exercising:

```dart
final service = RepoGitService(reposRoot: await Directory.systemTemp.createTemp());
final repo = GithubRepo(
  fullName: '<you>/git-agent-app-smoke-test',
  cloneUrl: 'https://github.com/<you>/git-agent-app-smoke-test.git',
  defaultBranch: 'main',
);
final dir = await service.cloneRepo(repo: repo, token: '<your PAT>');
await service.commitAndPush(
  repoDir: dir,
  relativeFilePath: 'smoke-test.md',
  content: '# smoke test\n\nhello from git_agent_app',
  commitMessage: 'smoke test',
  token: '<your PAT>',
);
```

Expected: no exception thrown, cloned files actually exist on disk with real content
(not just empty/missing blobs — this is exactly what failed silently with the previous
library), and `smoke-test.md` appears in the GitHub repo's `main` branch afterward
(verify in the browser or by cloning to a second location with plain `git`). This step
requires a human with real GitHub credentials — the implementer subagent cannot do this
itself; if dispatched as a subagent, report Steps 1-4 as done and this step as pending
human verification rather than skipping it silently.

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/git/repo_git_service.dart
git commit -m "feat: add RepoGitService for clone/commit/push via git2dart"
```

---

### Task 9: File tree builder

**Files:**
- Create: `lib/files/file_tree.dart`
- Test: `test/files/file_tree_test.dart`

**Interfaces:**
- Produces: `FileTreeNode`, `buildFileTree` — consumed by File Browser screen (Task 13) and Chat screen's save-folder picker (Task 14).

- [ ] **Step 1: Write the failing test**

```dart
// test/files/file_tree_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/files/file_tree.dart';

void main() {
  test('buildFileTree reflects nested directory structure with relative paths', () async {
    final root = await Directory.systemTemp.createTemp('file_tree_test');
    addTearDown(() => root.delete(recursive: true));

    await File('${root.path}/README.md').writeAsString('hi');
    final docsDir = await Directory('${root.path}/docs').create();
    await File('${docsDir.path}/guide.md').writeAsString('guide');

    final tree = await buildFileTree(root);

    expect(tree.isDirectory, isTrue);
    expect(tree.relativePath, '');

    final names = tree.children.map((c) => c.name).toSet();
    expect(names, {'README.md', 'docs'});

    final docsNode = tree.children.firstWhere((c) => c.name == 'docs');
    expect(docsNode.isDirectory, isTrue);
    expect(docsNode.children, hasLength(1));
    expect(docsNode.children.first.name, 'guide.md');
    expect(docsNode.children.first.relativePath, 'docs/guide.md');
    expect(docsNode.children.first.isDirectory, isFalse);
  });

  test('buildFileTree skips the .git directory', () async {
    final root = await Directory.systemTemp.createTemp('file_tree_test');
    addTearDown(() => root.delete(recursive: true));

    await Directory('${root.path}/.git').create();
    await File('${root.path}/README.md').writeAsString('hi');

    final tree = await buildFileTree(root);

    expect(tree.children.map((c) => c.name), ['README.md']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/files/file_tree_test.dart
```

Expected: FAIL — `lib/files/file_tree.dart` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```dart
// lib/files/file_tree.dart
import 'dart:io';
import 'package:path/path.dart' as p;

class FileTreeNode {
  final String name;
  final String relativePath;
  final bool isDirectory;
  final List<FileTreeNode> children;

  FileTreeNode({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.children,
  });
}

Future<FileTreeNode> buildFileTree(Directory root) async {
  return _buildNode(root, root, '');
}

Future<FileTreeNode> _buildNode(Directory root, Directory dir, String relativePath) async {
  final children = <FileTreeNode>[];
  final entries = await dir.list().toList();
  entries.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

  for (final entry in entries) {
    final name = p.basename(entry.path);
    if (name == '.git') continue;
    final childRelativePath = relativePath.isEmpty ? name : '$relativePath/$name';

    if (entry is Directory) {
      children.add(await _buildNode(root, entry, childRelativePath));
    } else if (entry is File) {
      children.add(FileTreeNode(
        name: name,
        relativePath: childRelativePath,
        isDirectory: false,
        children: const [],
      ));
    }
  }

  return FileTreeNode(
    name: p.basename(dir.path),
    relativePath: relativePath,
    isDirectory: true,
    children: children,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/files/file_tree_test.dart
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/files/file_tree.dart test/files/file_tree_test.dart
git commit -m "feat: add file tree builder for cloned repos"
```

---

### Task 10: Save-path resolver and structuring prompt builder

**Files:**
- Create: `lib/chat/save_path_resolver.dart`
- Create: `lib/chat/structuring_prompt.dart`
- Test: `test/chat/save_path_resolver_test.dart`
- Test: `test/chat/structuring_prompt_test.dart`

**Interfaces:**
- Produces: `resolveSavePath`, `buildStructuringPrompt` — consumed by Chat screen (Task 14).

- [ ] **Step 1: Write the failing tests**

```dart
// test/chat/save_path_resolver_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/save_path_resolver.dart';

void main() {
  test('resolves an explicit folder instruction, keeping the source filename', () {
    final path = resolveSavePath(
      instruction: 'save it in docs/posts/',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, 'docs/posts/raw-idea.md');
  });

  test('resolves an instruction that already includes a filename', () {
    final path = resolveSavePath(
      instruction: 'put it at content/blog/my-post.md',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, 'content/blog/my-post.md');
  });

  test('resolves a bare path with no lead-in words', () {
    final path = resolveSavePath(
      instruction: 'src/content/blog/',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, 'src/content/blog/raw-idea.md');
  });

  test('returns null for an instruction with no discernible path', () {
    final path = resolveSavePath(
      instruction: 'looks good, thanks!',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, isNull);
  });
}
```

```dart
// test/chat/structuring_prompt_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/structuring_prompt.dart';

void main() {
  test('includes rules and source content with no refinements', () {
    final prompt = buildStructuringPrompt(
      structureRules: '# Rules\n1. Do X.',
      sourceContent: 'raw text here',
      refinementRequests: const [],
    );
    expect(prompt, contains('# Rules'));
    expect(prompt, contains('1. Do X.'));
    expect(prompt, contains('raw text here'));
    expect(prompt, isNot(contains('Additional refinement')));
  });

  test('appends refinement requests in order when present', () {
    final prompt = buildStructuringPrompt(
      structureRules: '# Rules',
      sourceContent: 'raw text',
      refinementRequests: const ['make it shorter', 'add a summary section'],
    );
    final shorterIndex = prompt.indexOf('make it shorter');
    final summaryIndex = prompt.indexOf('add a summary section');
    expect(shorterIndex, greaterThan(-1));
    expect(summaryIndex, greaterThan(shorterIndex));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/chat/save_path_resolver_test.dart test/chat/structuring_prompt_test.dart
```

Expected: FAIL — neither implementation file exists yet.

- [ ] **Step 3: Write the implementations**

```dart
// lib/chat/save_path_resolver.dart
import 'package:path/path.dart' as p;

/// Resolves a chat instruction like "save it in docs/posts/" or
/// "put it at content/blog/my-post.md" into a repo-relative path.
/// Returns null when no path can be found in [instruction].
///
/// Rule: scan all whitespace-delimited tokens and pick the last one that
/// looks like a path (contains a "/"). Later mentions override earlier ones.
/// If it ends with "/", or has no file extension, treat it as a target
/// folder and append the source file's name with a ".md" extension.
/// Otherwise treat it as the full target file path as-is.
String? resolveSavePath({required String instruction, required String sourceRelativePath}) {
  final tokens = instruction.split(RegExp(r'\s+'));
  String? candidate;
  for (final token in tokens) {
    final cleaned = token.trim();
    if (cleaned.isEmpty) continue;
    if (cleaned.contains('/')) {
      candidate = cleaned;
    }
  }
  if (candidate == null) return null;

  final looksLikeFolder = candidate.endsWith('/') || p.extension(candidate).isEmpty;
  if (!looksLikeFolder) {
    return candidate;
  }

  final sourceBaseName = p.basenameWithoutExtension(sourceRelativePath);
  final folder = candidate.endsWith('/') ? candidate.substring(0, candidate.length - 1) : candidate;
  return '$folder/$sourceBaseName.md';
}
```

```dart
// lib/chat/structuring_prompt.dart
String buildStructuringPrompt({
  required String structureRules,
  required String sourceContent,
  required List<String> refinementRequests,
}) {
  final buffer = StringBuffer()
    ..writeln(structureRules)
    ..writeln()
    ..writeln('---')
    ..writeln()
    ..writeln('Source content to structure:')
    ..writeln()
    ..writeln(sourceContent);

  if (refinementRequests.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln('Additional refinement requests, apply in order:');
    for (final request in refinementRequests) {
      buffer.writeln('- $request');
    }
  }

  return buffer.toString();
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter test test/chat/save_path_resolver_test.dart test/chat/structuring_prompt_test.dart
```

Expected: PASS (6 tests total).

- [ ] **Step 5: Commit**

```bash
git add lib/chat/save_path_resolver.dart lib/chat/structuring_prompt.dart test/chat/save_path_resolver_test.dart test/chat/structuring_prompt_test.dart
git commit -m "feat: add save-path resolver and structuring prompt builder"
```

---

### Task 11: Settings screen

**Files:**
- Create: `lib/ui/settings_screen.dart`
- Modify: `lib/main.dart` (route to Settings as a reachable screen — full nav wiring happens in Task 15)

**Interfaces:**
- Consumes: `EngineSettings`/`EngineChoice` (Task 2), `SecretStore`/`secretKeyGithubPat` (Task 5).
- Produces: `SettingsScreen` widget — consumed by `main.dart` (Task 15).

- [ ] **Step 1: Write the implementation**

```dart
// lib/ui/settings_screen.dart
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';

class SettingsScreen extends StatefulWidget {
  final SecretStore secretStore;
  const SettingsScreen({super.key, required this.secretStore});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  EngineSettings _settings = const EngineSettings();
  final _patController = TextEditingController();
  final _endpointController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  final _headersController = TextEditingController();
  String? _structureMdOverridePath;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    final pat = await widget.secretStore.read(secretKeyGithubPat) ?? '';
    setState(() {
      _settings = settings;
      _patController.text = pat;
      _endpointController.text = settings.cloudEndpoint;
      _apiKeyController.text = settings.cloudApiKey;
      _modelController.text = settings.cloudModel;
      _headersController.text = settings.cloudHeaders;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final updated = _settings.copyWith(
      cloudEndpoint: _endpointController.text,
      cloudApiKey: _apiKeyController.text,
      cloudModel: _modelController.text,
      cloudHeaders: _headersController.text,
    );
    await updated.save(prefs);
    await widget.secretStore.write(secretKeyGithubPat, _patController.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  Future<void> _pickOnDeviceModel() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path != null) {
      setState(() => _settings = _settings.copyWith(onDeviceModelPath: path));
    }
  }

  Future<void> _importStructureMd() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path != null) {
      setState(() => _structureMdOverridePath = path);
    }
  }

  Future<void> _exportStructureMd() async {
    final path = _structureMdOverridePath;
    final content = path != null
        ? await File(path).readAsString()
        : await DefaultAssetBundle.of(context).loadString('assets/structure.md');
    final dir = await getTemporaryDirectory();
    final exportFile = File('${dir.path}/structure.md');
    await exportFile.writeAsString(content);
    await SharePlus.instance.share(ShareParams(files: [XFile(exportFile.path)]));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _patController,
            decoration: const InputDecoration(labelText: 'GitHub Personal Access Token'),
            obscureText: true,
          ),
          const SizedBox(height: 24),
          const Text('LLM Engine', style: TextStyle(fontWeight: FontWeight.bold)),
          RadioListTile<EngineChoice>(
            title: const Text('Cloud API'),
            value: EngineChoice.cloud,
            groupValue: _settings.choice,
            onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
          ),
          if (_settings.choice == EngineChoice.cloud) ...[
            TextField(
              controller: _endpointController,
              decoration: const InputDecoration(labelText: 'Cloud endpoint URL'),
            ),
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(labelText: 'Cloud API key'),
              obscureText: true,
            ),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(labelText: 'Model name (optional)'),
            ),
            TextField(
              controller: _headersController,
              decoration: const InputDecoration(labelText: 'Extra headers (Name: value per line)'),
              maxLines: 3,
            ),
          ],
          RadioListTile<EngineChoice>(
            title: const Text('On-device (.gguf)'),
            value: EngineChoice.onDevice,
            groupValue: _settings.choice,
            onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
          ),
          if (_settings.choice == EngineChoice.onDevice) ...[
            ListTile(
              title: Text(_settings.onDeviceModelPath.isEmpty
                  ? 'No model selected'
                  : _settings.onDeviceModelPath),
              trailing: ElevatedButton(onPressed: _pickOnDeviceModel, child: const Text('Choose file')),
            ),
          ],
          const SizedBox(height: 24),
          const Text('Structuring rules (structure.md)', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(_structureMdOverridePath ?? 'Using bundled default'),
          Row(
            children: [
              ElevatedButton(onPressed: _importStructureMd, child: const Text('Import')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _exportStructureMd, child: const Text('Export')),
            ],
          ),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter analyze lib/ui/settings_screen.dart
```

Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/ui/settings_screen.dart
git commit -m "feat: add Settings screen for GitHub PAT, LLM engine, structure.md"
```

---

### Task 12: Repo list screen

**Files:**
- Create: `lib/ui/repo_list_screen.dart`

**Interfaces:**
- Consumes: `GithubApi`/`GithubRepo` (Task 6), `RepoGitService` (Task 8), `SecretStore` (Task 5).
- Produces: `RepoListScreen` widget, which on tap navigates to `FileBrowserScreen` (Task 13) passing the cloned `Directory` and the `token`/`GithubRepo` needed later for push.

- [ ] **Step 1: Write the implementation**

```dart
// lib/ui/repo_list_screen.dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../git/repo_git_service.dart';
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
      setState(() => _repos = repos);
    } catch (e) {
      setState(() => _error = 'Failed to load repos: $e');
    }
  }

  Future<void> _clone(GithubRepo repo) async {
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) return;
    setState(() => _cloningFullName = repo.fullName);
    try {
      final reposRoot = await getApplicationDocumentsDirectory();
      final service = RepoGitService(reposRoot: reposRoot);
      final dir = await service.cloneRepo(repo: repo, token: token);
      if (!mounted) return;
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
                    return ListTile(
                      title: Text(repo.fullName),
                      trailing: _cloningFullName == repo.fullName
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download),
                      onTap: _cloningFullName == null ? () => _clone(repo) : null,
                    );
                  },
                ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter analyze lib/ui/repo_list_screen.dart
```

Expected: errors about `FileBrowserScreen` not existing yet are acceptable here — it's created in Task 13. Confirm no *other* errors, then proceed; Task 13's analyze step is the real gate.

- [ ] **Step 3: Commit**

```bash
git add lib/ui/repo_list_screen.dart
git commit -m "feat: add repo list screen with clone action"
```

---

### Task 13: File browser screen

**Files:**
- Create: `lib/ui/file_browser_screen.dart`

**Interfaces:**
- Consumes: `FileTreeNode`/`buildFileTree` (Task 9), `GithubRepo` (Task 6), `SecretStore` (Task 5).
- Produces: `FileBrowserScreen` widget, which on file tap navigates to `ChatScreen` (Task 14) passing the repo, repo dir, secret store, and selected file's relative path + content.

- [ ] **Step 1: Write the implementation**

```dart
// lib/ui/file_browser_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import '../files/file_tree.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import 'chat_screen.dart';

class FileBrowserScreen extends StatefulWidget {
  final GithubRepo repo;
  final Directory repoDir;
  final SecretStore secretStore;

  const FileBrowserScreen({
    super.key,
    required this.repo,
    required this.repoDir,
    required this.secretStore,
  });

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  FileTreeNode? _root;

  @override
  void initState() {
    super.initState();
    buildFileTree(widget.repoDir).then((tree) => setState(() => _root = tree));
  }

  Future<void> _openFile(FileTreeNode node) async {
    final content = await File('${widget.repoDir.path}/${node.relativePath}').readAsString();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        repo: widget.repo,
        repoDir: widget.repoDir,
        secretStore: widget.secretStore,
        sourceRelativePath: node.relativePath,
        sourceContent: content,
      ),
    ));
  }

  List<Widget> _tiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      tiles.add(Padding(
        padding: EdgeInsets.only(left: depth * 16.0),
        child: ListTile(
          leading: Icon(child.isDirectory ? Icons.folder : Icons.description),
          title: Text(child.name),
          onTap: child.isDirectory ? null : () => _openFile(child),
        ),
      ));
      if (child.isDirectory) {
        tiles.addAll(_tiles(child, depth + 1));
      }
    }
    return tiles;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.repo.fullName)),
      body: _root == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: _tiles(_root!, 0)),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter analyze lib/ui/file_browser_screen.dart lib/ui/repo_list_screen.dart
```

Expected: errors about `ChatScreen` not existing are acceptable — created in Task 14. No other errors.

- [ ] **Step 3: Commit**

```bash
git add lib/ui/file_browser_screen.dart
git commit -m "feat: add file browser screen for cloned repos"
```

---

### Task 14: Chat / refine / push screen

**Files:**
- Create: `lib/ui/chat_screen.dart`

**Interfaces:**
- Consumes: `EngineSettings`/`buildEngine` (Tasks 2, 4), `buildStructuringPrompt`/`resolveSavePath` (Task 10), `RepoGitService` (Task 8), `SecretStore` (Task 5), `FileTreeNode`/`buildFileTree` (Task 9).
- Produces: `ChatScreen` widget — the terminal screen in the flow, wired into `main.dart` navigation from Task 13.

- [ ] **Step 1: Write the implementation**

```dart
// lib/ui/chat_screen.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chat/save_path_resolver.dart';
import '../chat/structuring_prompt.dart';
import '../engine/engine_factory.dart';
import '../engine/llm_engine.dart';
import '../git/repo_git_service.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';

class _ChatMessage {
  final String text;
  final bool fromUser;
  const _ChatMessage(this.text, {required this.fromUser});
}

class ChatScreen extends StatefulWidget {
  final GithubRepo repo;
  final Directory repoDir;
  final SecretStore secretStore;
  final String sourceRelativePath;
  final String sourceContent;

  const ChatScreen({
    super.key,
    required this.repo,
    required this.repoDir,
    required this.secretStore,
    required this.sourceRelativePath,
    required this.sourceContent,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_ChatMessage> _messages = [];
  final List<String> _refinements = [];
  final _inputController = TextEditingController();
  LlmEngine? _engine;
  String _structureRules = '';
  String? _latestStructuredContent;
  String? _resolvedSavePath;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    final engine = buildEngine(settings);
    _structureRules = await DefaultAssetBundle.of(context).loadString('assets/structure.md');
    if (engine == null) {
      setState(() {
        _messages.add(const _ChatMessage(
          'No LLM configured. Go to Settings and set up a Cloud API or On-device engine first.',
          fromUser: false,
        ));
      });
      return;
    }
    _engine = engine;
    await _generate();
  }

  Future<void> _generate() async {
    if (_engine == null) return;
    setState(() => _busy = true);
    try {
      final prompt = buildStructuringPrompt(
        structureRules: _structureRules,
        sourceContent: widget.sourceContent,
        refinementRequests: _refinements,
      );
      final result = await _engine!.generate(prompt);
      setState(() {
        _latestStructuredContent = result;
        _messages.add(_ChatMessage(result, fromUser: false));
      });
    } catch (e) {
      setState(() => _messages.add(_ChatMessage('Generation failed: $e', fromUser: false)));
    } finally {
      setState(() => _busy = false);
    }
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();

    final resolved = resolveSavePath(instruction: text, sourceRelativePath: widget.sourceRelativePath);
    setState(() {
      _messages.add(_ChatMessage(text, fromUser: true));
      if (resolved != null) {
        _resolvedSavePath = resolved;
        _messages.add(_ChatMessage('Save path set to: $resolved', fromUser: false));
      } else {
        _refinements.add(text);
      }
    });

    if (resolved == null) {
      _generate();
    }
  }

  Future<void> _push() async {
    final content = _latestStructuredContent;
    final savePath = _resolvedSavePath;
    if (content == null || savePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Generate a result and set a save path (via chat) before pushing.'),
      ));
      return;
    }
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) return;

    setState(() => _busy = true);
    try {
      final service = RepoGitService(reposRoot: widget.repoDir.parent);
      await service.commitAndPush(
        repoDir: widget.repoDir,
        relativeFilePath: savePath,
        content: content,
        commitMessage: 'Add structured content at $savePath',
        token: token,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pushed successfully')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Push failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.sourceRelativePath)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final m = _messages[index];
                return Align(
                  alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: m.fromUser ? Colors.blue[100] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(m.text),
                  ),
                );
              },
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: const InputDecoration(
                      hintText: 'Refine, or say "save it in docs/posts/"',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _busy ? null : _send),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _push,
                child: const Text('Push to repo'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter analyze lib/ui/chat_screen.dart lib/ui/file_browser_screen.dart lib/ui/repo_list_screen.dart lib/ui/settings_screen.dart
```

Expected: `No issues found!` — this is the point where all four screens' cross-references resolve. Fix any leftover import/type mismatches now (e.g. missing `import 'dart:io';` for `Directory` in `repo_list_screen.dart`/`file_browser_screen.dart`).

- [ ] **Step 3: Commit**

```bash
git add lib/ui/chat_screen.dart
git commit -m "feat: add chat/refine/push screen"
```

---

### Task 15: Wire navigation and run end-to-end

**Files:**
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `SettingsScreen` (Task 11), `RepoListScreen` (Task 12), `SecureSecretStore` (Task 5).

Task 8's git2dart research found that `git2dart` requires a one-time native init call,
`PlatformSpecific.initialize()`, before any git2dart usage — it configures Android SSL
certs and eagerly loads libgit2. This must run at app startup, before `main.dart`'s
first screen can reach the clone/push code paths.

- [ ] **Step 1: Write the implementation**

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:git2dart/git2dart.dart';
import 'secrets/secret_store.dart';
import 'ui/repo_list_screen.dart';
import 'ui/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PlatformSpecific.initialize();
  runApp(const GitAgentApp());
}

class GitAgentApp extends StatelessWidget {
  const GitAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    final secretStore = SecureSecretStore();
    return MaterialApp(
      title: 'git_agent_app',
      home: HomeScreen(secretStore: secretStore),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final SecretStore secretStore;
  const HomeScreen({super.key, required this.secretStore});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('git_agent_app'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SettingsScreen(secretStore: secretStore),
            )),
          ),
        ],
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RepoListScreen(secretStore: secretStore),
          )),
          child: const Text('Browse your repositories'),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run the full test suite**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter analyze
flutter test
```

Expected: `No issues found!` and all unit tests from Tasks 2, 3, 4, 6, 7, 9, 10 pass (17 tests total).

- [ ] **Step 3: Manual end-to-end smoke test**

With an Android device or emulator connected:

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
cd /media/asterisk/windows_drive/project/learn/my_learning_projects/git_agent_app
flutter run
```

Walk through: Settings (enter PAT + cloud API key/endpoint) → back → "Browse your
repositories" → tap a real repo to clone → tap a file → confirm structured output
appears in chat → type "save it in <some-folder>/" → confirm the save-path
confirmation message appears → tap "Push to repo" → confirm success snackbar and
verify the file landed at the expected path in the GitHub repo.

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart
git commit -m "feat: wire navigation for git_agent_app v1 flow"
```

---

## Self-Review Notes

- **Spec coverage:** Settings (PAT, engine toggle, structure.md import/export) → Task 11; repo list + clone → Task 12; file browser → Task 13; chat refine + save-path-by-chat + push → Task 14; no-fake-engine blocking → Task 4 + Task 14 Step 1; save-path resolver unit tests → Task 10; git library risk called out and smoke-tested → Task 8 (twice-swapped during
  implementation: dart_git → git_on_dart → git2dart, after both prior libraries proved
  to not actually implement working HTTPS transfer). All spec sections have a task.
- **Placeholder scan:** no TBD/TODO; the one caveat (Task 8's "adjust names if the installed version differs") is disclosed as real friction with a fresh package, not a placeholder — it's paired with an exact verification command and a required manual smoke test before the task is considered done.
- **Type consistency:** `LlmEngine.generate(String) -> Future<String>` used consistently in Tasks 3, 4, 14. `EngineSettings`/`EngineChoice` fields identical between Task 2 and all consumers. `GithubRepo` fields (`fullName`, `cloneUrl`, `defaultBranch`) consistent across Tasks 6, 8, 12, 13, 14. `FileTreeNode` fields consistent between Task 9 and Task 13.
