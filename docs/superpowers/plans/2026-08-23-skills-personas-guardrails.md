# Skills, Personas, Guardrails + On-device Load Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add named skills (one-time slash-triggered prompt additions), personas (role-framing, default or slash-switched), always-on guardrails, and an honest on-device model-load elapsed-time indicator to the existing git_agent_app chat screen.

**Architecture:** One generic `InstructionLibrary` class (JSON manifest + per-slug `.md` content files) backs both a Skills library and a Personas library, each a separate instance rooted in its own app-storage subdirectory. A separate `AgentConfig` model (SharedPreferences-backed, same pattern as `EngineSettings`) holds the default persona slug and guardrails text. The chat screen gains a pure slash-command parser checked before the existing refinement/save-path logic, and `buildStructuringPrompt` gains three optional parameters composed in a fixed order. The on-device load indicator is a `Timer.periodic` in `chat_screen.dart` with no changes to `OnDeviceLlamaEngine`.

**Tech Stack:** Flutter/Dart, `shared_preferences` (AgentConfig), `path_provider` (library root dirs), `dart:convert` (JSON manifest), `dart:async` Timer (load indicator). No new dependencies.

## Global Constraints

- Slug format: lowercase kebab-case, derived from `name` via slugify (non-alphanumeric runs → single `-`, trimmed).
- `InstructionLibrary.add()` throws `StateError` on a slug collision — never silently overwrites.
- `InstructionLibrary.delete()` on a nonexistent slug is a no-op.
- Slash-command grammar matches the **whole trimmed message only**: `^/([a-z0-9-]+)(:([a-z0-9-]+))?$`. Anything else (a message merely containing a slash, or a `/`-led message with trailing words) is not a command and falls through to existing chat logic unchanged.
- `buildStructuringPrompt`'s three new parameters (`guardrails`, `personaContent`, `skillContent`) all default to empty/null so existing call sites and existing tests keep producing byte-identical output.
- Composition order: guardrails → persona content → base structure rules → one-time skill content → source content → refinement requests.
- Deleting a persona/skill that is currently active (session override or `AgentConfig` default) must fail safe: prompt composition proceeds as if none was set, never a crash or stale content.
- No percentage-based load progress — elapsed-time counter only (installed `llama_cpp_dart 0.0.9` has no real progress hook).
- Bundled starter personas ship as assets and are copied into the personas library only when that library is empty on first run; users can edit/delete any of them like their own entries.

---

### Task 1: `InstructionEntry` + `InstructionLibrary`

**Files:**
- Create: `lib/instructions/instruction_library.dart`
- Test: `test/instructions/instruction_library_test.dart`

**Interfaces:**
- Produces:
  - `class InstructionEntry { final String slug; final String name; final String description; final String content; const InstructionEntry({required this.slug, required this.name, required this.description, required this.content}); }`
  - `String slugify(String input)`
  - `class InstructionLibrary { InstructionLibrary({required Directory root}); Future<List<InstructionEntry>> list(); Future<InstructionEntry> add({required String name, required String description, required String content}); Future<void> update(String slug, {String? name, String? description, String? content}); Future<void> delete(String slug); Future<String?> contentFor(String slug); }`

- [ ] **Step 1: Write the failing tests**

```dart
// test/instructions/instruction_library_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/instructions/instruction_library.dart';

void main() {
  late Directory tempDir;
  late InstructionLibrary library;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('instruction_library_test_');
    library = InstructionLibrary(root: Directory('${tempDir.path}/lib_root'));
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('slugify lowercases and hyphenates', () {
    expect(slugify('Code Reviewer'), 'code-reviewer');
    expect(slugify('  Solution   Architect! '), 'solution-architect');
  });

  test('list is empty for a fresh library', () async {
    expect(await library.list(), isEmpty);
  });

  test('add creates an entry retrievable via list and contentFor', () async {
    final entry = await library.add(
      name: 'Code Reviewer',
      description: 'Reviews code for correctness',
      content: '# Code Reviewer\nThink like a reviewer.',
    );
    expect(entry.slug, 'code-reviewer');

    final all = await library.list();
    expect(all, hasLength(1));
    expect(all.single.name, 'Code Reviewer');
    expect(all.single.description, 'Reviews code for correctness');
    expect(all.single.content, contains('Think like a reviewer.'));

    expect(await library.contentFor('code-reviewer'), contains('Think like a reviewer.'));
  });

  test('add rejects a slug collision', () async {
    await library.add(name: 'Debugger', description: 'd1', content: 'c1');
    expect(
      () => library.add(name: 'Debugger', description: 'd2', content: 'c2'),
      throwsStateError,
    );
  });

  test('update changes metadata and content independently', () async {
    await library.add(name: 'Analyst', description: 'orig desc', content: 'orig content');
    await library.update('analyst', description: 'new desc');
    var all = await library.list();
    expect(all.single.description, 'new desc');
    expect(all.single.content, 'orig content');

    await library.update('analyst', content: 'new content');
    all = await library.list();
    expect(all.single.content, 'new content');
    expect(all.single.description, 'new desc');
  });

  test('delete removes an entry; deleting a nonexistent slug is a no-op', () async {
    await library.add(name: 'Validator', description: 'v', content: 'vc');
    await library.delete('validator');
    expect(await library.list(), isEmpty);
    expect(await library.contentFor('validator'), isNull);

    await library.delete('does-not-exist'); // must not throw
  });

  test('contentFor returns null for an unknown slug', () async {
    expect(await library.contentFor('nope'), isNull);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/instructions/instruction_library_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/instructions/instruction_library.dart'`

- [ ] **Step 3: Implement**

```dart
// lib/instructions/instruction_library.dart
import 'dart:convert';
import 'dart:io';

class InstructionEntry {
  final String slug;
  final String name;
  final String description;
  final String content;

  const InstructionEntry({
    required this.slug,
    required this.name,
    required this.description,
    required this.content,
  });
}

String slugify(String input) {
  final lowered = input.toLowerCase().trim();
  final hyphenated = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return hyphenated.replaceAll(RegExp(r'^-+|-+$'), '');
}

class InstructionLibrary {
  final Directory root;

  InstructionLibrary({required this.root});

  File get _manifestFile => File('${root.path}/manifest.json');
  File _contentFile(String slug) => File('${root.path}/$slug.md');

  Future<Map<String, dynamic>> _readManifest() async {
    if (!await _manifestFile.exists()) return {};
    final text = await _manifestFile.readAsString();
    if (text.trim().isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _writeManifest(Map<String, dynamic> manifest) async {
    await root.create(recursive: true);
    await _manifestFile.writeAsString(jsonEncode(manifest));
  }

  Future<List<InstructionEntry>> list() async {
    final manifest = await _readManifest();
    final entries = <InstructionEntry>[];
    for (final slug in manifest.keys) {
      final meta = manifest[slug] as Map<String, dynamic>;
      final content = await contentFor(slug) ?? '';
      entries.add(InstructionEntry(
        slug: slug,
        name: meta['name'] as String,
        description: meta['description'] as String,
        content: content,
      ));
    }
    return entries;
  }

  Future<InstructionEntry> add({
    required String name,
    required String description,
    required String content,
  }) async {
    final slug = slugify(name);
    final manifest = await _readManifest();
    if (manifest.containsKey(slug)) {
      throw StateError('An entry with slug "$slug" already exists');
    }
    manifest[slug] = {'name': name, 'description': description};
    await _writeManifest(manifest);
    await _contentFile(slug).writeAsString(content);
    return InstructionEntry(slug: slug, name: name, description: description, content: content);
  }

  Future<void> update(String slug, {String? name, String? description, String? content}) async {
    final manifest = await _readManifest();
    final meta = manifest[slug] as Map<String, dynamic>?;
    if (meta == null) throw StateError('No entry with slug "$slug"');
    if (name != null) meta['name'] = name;
    if (description != null) meta['description'] = description;
    manifest[slug] = meta;
    await _writeManifest(manifest);
    if (content != null) {
      await _contentFile(slug).writeAsString(content);
    }
  }

  Future<void> delete(String slug) async {
    final manifest = await _readManifest();
    if (!manifest.containsKey(slug)) return;
    manifest.remove(slug);
    await _writeManifest(manifest);
    final file = _contentFile(slug);
    if (await file.exists()) await file.delete();
  }

  Future<String?> contentFor(String slug) async {
    final file = _contentFile(slug);
    if (!await file.exists()) return null;
    return file.readAsString();
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/instructions/instruction_library_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/instructions/instruction_library.dart test/instructions/instruction_library_test.dart
git commit -m "feat: add InstructionLibrary for skills/personas storage"
```

---

### Task 2: `AgentConfig`

**Files:**
- Create: `lib/settings/agent_config.dart`
- Test: `test/settings/agent_config_test.dart`

**Interfaces:**
- Consumes: `shared_preferences`'s `SharedPreferences` (already used by `EngineSettings`).
- Produces:
  - `class AgentConfig { final String? defaultPersonaSlug; final String guardrails; const AgentConfig({this.defaultPersonaSlug, this.guardrails = ''}); AgentConfig copyWith({String? defaultPersonaSlug, bool clearPersona = false, String? guardrails}); static Future<AgentConfig> load(SharedPreferences prefs); Future<void> save(SharedPreferences prefs); }`

- [ ] **Step 1: Write the failing tests**

```dart
// test/settings/agent_config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:git_agent_app/settings/agent_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load returns defaults when nothing saved', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final config = await AgentConfig.load(prefs);
    expect(config.defaultPersonaSlug, isNull);
    expect(config.guardrails, '');
  });

  test('save then load round-trips persona slug and guardrails', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const config = AgentConfig(defaultPersonaSlug: 'code-reviewer', guardrails: 'Never invent facts.');
    await config.save(prefs);

    final loaded = await AgentConfig.load(prefs);
    expect(loaded.defaultPersonaSlug, 'code-reviewer');
    expect(loaded.guardrails, 'Never invent facts.');
  });

  test('copyWith with clearPersona removes the default persona', () async {
    const config = AgentConfig(defaultPersonaSlug: 'debugger', guardrails: 'g');
    final cleared = config.copyWith(clearPersona: true);
    expect(cleared.defaultPersonaSlug, isNull);
    expect(cleared.guardrails, 'g');
  });

  test('saving a null defaultPersonaSlug removes any previously saved value', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await const AgentConfig(defaultPersonaSlug: 'analyst').save(prefs);
    await const AgentConfig().save(prefs);

    final loaded = await AgentConfig.load(prefs);
    expect(loaded.defaultPersonaSlug, isNull);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/settings/agent_config_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/settings/agent_config.dart'`

- [ ] **Step 3: Implement**

```dart
// lib/settings/agent_config.dart
import 'package:shared_preferences/shared_preferences.dart';

class AgentConfig {
  final String? defaultPersonaSlug;
  final String guardrails;

  const AgentConfig({this.defaultPersonaSlug, this.guardrails = ''});

  AgentConfig copyWith({
    String? defaultPersonaSlug,
    bool clearPersona = false,
    String? guardrails,
  }) {
    return AgentConfig(
      defaultPersonaSlug: clearPersona ? null : (defaultPersonaSlug ?? this.defaultPersonaSlug),
      guardrails: guardrails ?? this.guardrails,
    );
  }

  static const _keyPersona = 'agent_default_persona_slug';
  static const _keyGuardrails = 'agent_guardrails';

  static Future<AgentConfig> load(SharedPreferences prefs) async {
    return AgentConfig(
      defaultPersonaSlug: prefs.getString(_keyPersona),
      guardrails: prefs.getString(_keyGuardrails) ?? '',
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    if (defaultPersonaSlug == null) {
      await prefs.remove(_keyPersona);
    } else {
      await prefs.setString(_keyPersona, defaultPersonaSlug!);
    }
    await prefs.setString(_keyGuardrails, guardrails);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/settings/agent_config_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/settings/agent_config.dart test/settings/agent_config_test.dart
git commit -m "feat: add AgentConfig for default persona and guardrails"
```

---

### Task 3: Bundled starter personas + seeding

**Files:**
- Create: `assets/personas/code_reviewer.md`
- Create: `assets/personas/debugger.md`
- Create: `assets/personas/solution_architect.md`
- Create: `assets/personas/validator.md`
- Create: `assets/personas/analyst.md`
- Create: `assets/personas/seo_optimizer.md`
- Create: `assets/personas/security_analyst.md`
- Create: `lib/instructions/starter_personas.dart`
- Modify: `pubspec.yaml` (assets list)
- Test: `test/instructions/starter_personas_test.dart`

**Interfaces:**
- Consumes: `InstructionLibrary` (Task 1).
- Produces: `const Map<String, String> starterPersonaAssets` (display name → asset path), `Future<void> seedStarterPersonasIfEmpty(InstructionLibrary personas, Future<String> Function(String assetPath) loadAsset)`.

The seeding function takes a plain asset-loader callback (not `AssetBundle` directly) so it stays testable without a widget test harness; the chat/settings screens pass `DefaultAssetBundle.of(context).loadString`.

- [ ] **Step 1: Write the persona content files**

```markdown
<!-- assets/personas/code_reviewer.md -->
# Code Reviewer

Think like a meticulous code reviewer. Prioritize correctness, edge cases, and
maintainability over style preferences. Call out anything that could break in
production before suggesting improvements. Be specific: point to exact lines
or conditions, not vague concerns.
```

```markdown
<!-- assets/personas/debugger.md -->
# Debugger

Think like a systematic debugger. Start from the observed symptom, form a
hypothesis, and identify what evidence would confirm or rule it out before
proposing a fix. Prefer root-cause fixes over patches that only hide the
symptom.
```

```markdown
<!-- assets/personas/solution_architect.md -->
# Solution Architect

Think like a solution architect. Weigh trade-offs explicitly (simplicity,
scalability, maintainability) before recommending an approach. Call out
assumptions and constraints that shape the recommendation.
```

```markdown
<!-- assets/personas/validator.md -->
# Validator

Think like a validator. Check the content against its own stated rules and
requirements point by point. Flag anything unverified, inconsistent, or
missing rather than assuming it is correct.
```

```markdown
<!-- assets/personas/analyst.md -->
# Analyst

Think like an analyst. Organize information clearly, surface patterns and
notable data points, and separate observations from conclusions.
```

```markdown
<!-- assets/personas/seo_optimizer.md -->
# SEO Optimizer

Think like an SEO optimizer. Favor clear headings, scannable structure, and
descriptive terms a reader would actually search for, without sacrificing
accuracy or stuffing keywords unnaturally.
```

```markdown
<!-- assets/personas/security_analyst.md -->
# Security Analyst

Think like a security analyst. Flag anything that touches secrets,
credentials, permissions, or user input handling. Prefer calling out a risk
explicitly over silently working around it.
```

- [ ] **Step 2: Register the assets in `pubspec.yaml`**

Edit the `flutter: assets:` list in `pubspec.yaml`:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/structure.md
    - assets/personas/code_reviewer.md
    - assets/personas/debugger.md
    - assets/personas/solution_architect.md
    - assets/personas/validator.md
    - assets/personas/analyst.md
    - assets/personas/seo_optimizer.md
    - assets/personas/security_analyst.md
```

Run: `flutter pub get`
Expected: completes with no errors.

- [ ] **Step 3: Write the failing test**

```dart
// test/instructions/starter_personas_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/instructions/instruction_library.dart';
import 'package:git_agent_app/instructions/starter_personas.dart';

void main() {
  late Directory tempDir;
  late InstructionLibrary personas;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('starter_personas_test_');
    personas = InstructionLibrary(root: Directory('${tempDir.path}/personas'));
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> fakeLoadAsset(String path) async => 'content for $path';

  test('seeds all starter personas into an empty library', () async {
    await seedStarterPersonasIfEmpty(personas, fakeLoadAsset);
    final all = await personas.list();
    expect(all, hasLength(starterPersonaAssets.length));
    final names = all.map((e) => e.name).toSet();
    expect(names, starterPersonaAssets.keys.toSet());
  });

  test('does nothing if the library already has entries', () async {
    await personas.add(name: 'Custom Persona', description: 'd', content: 'c');
    await seedStarterPersonasIfEmpty(personas, fakeLoadAsset);
    final all = await personas.list();
    expect(all, hasLength(1));
    expect(all.single.name, 'Custom Persona');
  });
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `flutter test test/instructions/starter_personas_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/instructions/starter_personas.dart'`

- [ ] **Step 5: Implement**

```dart
// lib/instructions/starter_personas.dart
import 'instruction_library.dart';

const starterPersonaAssets = <String, String>{
  'Code Reviewer': 'assets/personas/code_reviewer.md',
  'Debugger': 'assets/personas/debugger.md',
  'Solution Architect': 'assets/personas/solution_architect.md',
  'Validator': 'assets/personas/validator.md',
  'Analyst': 'assets/personas/analyst.md',
  'SEO Optimizer': 'assets/personas/seo_optimizer.md',
  'Security Analyst': 'assets/personas/security_analyst.md',
};

Future<void> seedStarterPersonasIfEmpty(
  InstructionLibrary personas,
  Future<String> Function(String assetPath) loadAsset,
) async {
  final existing = await personas.list();
  if (existing.isNotEmpty) return;
  for (final entry in starterPersonaAssets.entries) {
    final content = await loadAsset(entry.value);
    await personas.add(name: entry.key, description: '${entry.key} persona', content: content);
  }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `flutter test test/instructions/starter_personas_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 7: Commit**

```bash
git add assets/personas pubspec.yaml lib/instructions/starter_personas.dart test/instructions/starter_personas_test.dart
git commit -m "feat: bundle starter personas and seed them on first run"
```

---

### Task 4: Slash-command parser

**Files:**
- Create: `lib/chat/slash_command.dart`
- Test: `test/chat/slash_command_test.dart`

**Interfaces:**
- Produces:
  - `sealed class SlashCommand {}`
  - `class SkillCommand extends SlashCommand { final String slug; SkillCommand(this.slug); }`
  - `class PersonaCommand extends SlashCommand { final String slug; PersonaCommand(this.slug); }`
  - `SlashCommand? parseSlashCommand(String text)`

- [ ] **Step 1: Write the failing tests**

```dart
// test/chat/slash_command_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/slash_command.dart';

void main() {
  test('parses a bare skill slug', () {
    final cmd = parseSlashCommand('/code-review');
    expect(cmd, isA<SkillCommand>());
    expect((cmd as SkillCommand).slug, 'code-review');
  });

  test('parses a persona command', () {
    final cmd = parseSlashCommand('/persona:debugger');
    expect(cmd, isA<PersonaCommand>());
    expect((cmd as PersonaCommand).slug, 'debugger');
  });

  test('trims surrounding whitespace before matching', () {
    final cmd = parseSlashCommand('  /persona:analyst  ');
    expect(cmd, isA<PersonaCommand>());
  });

  test('a message that merely contains a slash is not a command', () {
    expect(parseSlashCommand('add a section on CI/CD'), isNull);
  });

  test('a message starting with / but with trailing words is not a command', () {
    expect(parseSlashCommand('/code-review please run it'), isNull);
  });

  test('an unknown colon prefix (not persona) is not a command', () {
    expect(parseSlashCommand('/foo:bar'), isNull);
  });

  test('empty and bare-slash inputs are not commands', () {
    expect(parseSlashCommand(''), isNull);
    expect(parseSlashCommand('/'), isNull);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/chat/slash_command_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/chat/slash_command.dart'`

- [ ] **Step 3: Implement**

```dart
// lib/chat/slash_command.dart
sealed class SlashCommand {}

class SkillCommand extends SlashCommand {
  final String slug;
  SkillCommand(this.slug);
}

class PersonaCommand extends SlashCommand {
  final String slug;
  PersonaCommand(this.slug);
}

final _slashPattern = RegExp(r'^/([a-z0-9-]+)(:([a-z0-9-]+))?$');

SlashCommand? parseSlashCommand(String text) {
  final trimmed = text.trim();
  final match = _slashPattern.firstMatch(trimmed);
  if (match == null) return null;

  final prefix = match.group(1)!;
  final suffix = match.group(3);

  if (suffix != null) {
    return prefix == 'persona' ? PersonaCommand(suffix) : null;
  }
  return SkillCommand(prefix);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/chat/slash_command_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/chat/slash_command.dart test/chat/slash_command_test.dart
git commit -m "feat: add slash-command parser for skills and personas"
```

---

### Task 5: Extend `buildStructuringPrompt` composition

**Files:**
- Modify: `lib/chat/structuring_prompt.dart`
- Modify: `test/chat/structuring_prompt_test.dart`

**Interfaces:**
- Produces: `String buildStructuringPrompt({required String structureRules, required String sourceContent, required List<String> refinementRequests, String guardrails = '', String? personaContent, String? skillContent})`

- [ ] **Step 1: Write the failing tests (append to the existing file)**

```dart
// Append to test/chat/structuring_prompt_test.dart, inside main()
  test('omitting new params reproduces the exact prior output', () {
    final prompt = buildStructuringPrompt(
      structureRules: '# Rules\n1. Do X.',
      sourceContent: 'raw text here',
      refinementRequests: const [],
    );
    expect(prompt, '''
# Rules
1. Do X.

---

Source content to structure:

raw text here
''');
  });

  test('composes guardrails, persona, skill in the specified order', () {
    final prompt = buildStructuringPrompt(
      structureRules: 'BASE_RULES',
      sourceContent: 'SOURCE',
      refinementRequests: const ['REFINEMENT'],
      guardrails: 'GUARDRAILS_TEXT',
      personaContent: 'PERSONA_TEXT',
      skillContent: 'SKILL_TEXT',
    );
    final order = [
      'GUARDRAILS_TEXT',
      'PERSONA_TEXT',
      'BASE_RULES',
      'SKILL_TEXT',
      'SOURCE',
      'REFINEMENT',
    ];
    var lastIndex = -1;
    for (final marker in order) {
      final index = prompt.indexOf(marker);
      expect(index, greaterThan(lastIndex), reason: '$marker out of order');
      lastIndex = index;
    }
  });

  test('empty guardrails and null persona/skill are omitted entirely', () {
    final prompt = buildStructuringPrompt(
      structureRules: 'RULES',
      sourceContent: 'SOURCE',
      refinementRequests: const [],
      guardrails: '   ',
    );
    expect(prompt, isNot(contains('Guardrails')));
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/chat/structuring_prompt_test.dart`
Expected: FAIL — extra named parameters not defined on `buildStructuringPrompt`

- [ ] **Step 3: Implement**

```dart
// lib/chat/structuring_prompt.dart
String buildStructuringPrompt({
  required String structureRules,
  required String sourceContent,
  required List<String> refinementRequests,
  String guardrails = '',
  String? personaContent,
  String? skillContent,
}) {
  final buffer = StringBuffer();

  if (guardrails.trim().isNotEmpty) {
    buffer
      ..writeln('Guardrails (always apply):')
      ..writeln(guardrails)
      ..writeln()
      ..writeln('---')
      ..writeln();
  }

  if (personaContent != null && personaContent.trim().isNotEmpty) {
    buffer
      ..writeln(personaContent)
      ..writeln()
      ..writeln('---')
      ..writeln();
  }

  buffer.writeln(structureRules);

  if (skillContent != null && skillContent.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln(skillContent);
  }

  buffer
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

Run: `flutter test test/chat/structuring_prompt_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/chat/structuring_prompt.dart test/chat/structuring_prompt_test.dart
git commit -m "feat: compose guardrails/persona/skill content into structuring prompt"
```

---

### Task 6: Settings screen — Skills, Personas, Guardrails sections

**Files:**
- Modify: `lib/ui/settings_screen.dart`

**Interfaces:**
- Consumes: `InstructionLibrary`, `InstructionEntry`, `seedStarterPersonasIfEmpty`, `starterPersonaAssets` (Tasks 1 & 3), `AgentConfig` (Task 2).
- Produces: no new public API — this is leaf UI. Later tasks don't depend on anything new here.

No unit tests for this screen — `settings_screen.dart` has none today (verified: only pure-logic files have test coverage in this project). Verify via `flutter analyze` and a manual on-device smoke test at the end of this task.

- [ ] **Step 1: Add library instances, AgentConfig state, and controllers**

In `lib/ui/settings_screen.dart`, add imports and state:

```dart
// add to imports
import '../instructions/instruction_library.dart';
import '../instructions/starter_personas.dart';
import '../settings/agent_config.dart';
```

In `_SettingsScreenState`, add fields:

```dart
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  List<InstructionEntry> _skills = [];
  List<InstructionEntry> _personas = [];
  AgentConfig _agentConfig = const AgentConfig();
  final _guardrailsController = TextEditingController();
```

- [ ] **Step 2: Load libraries and AgentConfig in `_load()`**

Replace the body of `_load()` with:

```dart
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    final agentConfig = await AgentConfig.load(prefs);
    final pat = await widget.secretStore.read(secretKeyGithubPat) ?? '';
    final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';

    final docs = await getApplicationDocumentsDirectory();
    final skillsLibrary = InstructionLibrary(root: Directory('${docs.path}/skills'));
    final personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
    if (mounted) {
      await seedStarterPersonasIfEmpty(
        personasLibrary,
        (path) => DefaultAssetBundle.of(context).loadString(path),
      );
    }
    final skills = await skillsLibrary.list();
    final personas = await personasLibrary.list();

    setState(() {
      _settings = settings;
      _agentConfig = agentConfig;
      _patController.text = pat;
      _endpointController.text = settings.cloudEndpoint;
      _apiKeyController.text = apiKey;
      _modelController.text = settings.cloudModel;
      _headersController.text = settings.cloudHeaders;
      _guardrailsController.text = agentConfig.guardrails;
      _structureMdOverridePath =
          settings.structureMdOverridePath.isEmpty ? null : settings.structureMdOverridePath;
      _skillsLibrary = skillsLibrary;
      _personasLibrary = personasLibrary;
      _skills = skills;
      _personas = personas;
      _loading = false;
    });
  }
```

Add the missing import for `Directory` and `path_provider` (already imported for `getTemporaryDirectory`, confirm `getApplicationDocumentsDirectory` is exported by the same `path_provider` package — it is).

- [ ] **Step 3: Persist guardrails and default persona in `_save()`**

Modify `_save()`:

```dart
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final updated = _settings.copyWith(
      cloudEndpoint: _endpointController.text,
      cloudModel: _modelController.text,
      cloudHeaders: _headersController.text,
    );
    await updated.save(prefs);
    await widget.secretStore.write(secretKeyGithubPat, _patController.text);
    await widget.secretStore.write(secretKeyCloudApiKey, _apiKeyController.text);

    final updatedAgentConfig = _agentConfig.copyWith(guardrails: _guardrailsController.text);
    await updatedAgentConfig.save(prefs);
    _agentConfig = updatedAgentConfig;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }
```

- [ ] **Step 4: Add an entry-editor dialog helper**

Add this method to `_SettingsScreenState` — shared by both Skills and Personas Add/Edit flows:

```dart
  Future<void> _showEntryEditor({
    required InstructionLibrary library,
    required List<InstructionEntry> currentEntries,
    required void Function(List<InstructionEntry>) onUpdated,
    InstructionEntry? existing,
  }) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final descriptionController = TextEditingController(text: existing?.description ?? '');
    final contentController = TextEditingController(text: existing?.content ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'Add' : 'Edit'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                enabled: existing == null, // slug is derived from name at creation only
              ),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              TextField(
                controller: contentController,
                decoration: const InputDecoration(labelText: 'Content (Markdown)'),
                maxLines: 6,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
        ],
      ),
    );

    if (saved != true) return;

    try {
      if (existing == null) {
        await library.add(
          name: nameController.text,
          description: descriptionController.text,
          content: contentController.text,
        );
      } else {
        await library.update(
          existing.slug,
          description: descriptionController.text,
          content: contentController.text,
        );
      }
      onUpdated(await library.list());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }
```

- [ ] **Step 5: Add Skills and Personas list sections to `build()`**

Insert this helper method and call it from `build()` for both libraries:

```dart
  Widget _instructionSection({
    required String title,
    required InstructionLibrary? library,
    required List<InstructionEntry> entries,
    required void Function(List<InstructionEntry>) onUpdated,
  }) {
    if (library == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        for (final entry in entries)
          ListTile(
            title: Text(entry.name),
            subtitle: Text(entry.description),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _showEntryEditor(
                    library: library,
                    currentEntries: entries,
                    onUpdated: onUpdated,
                    existing: entry,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () async {
                    await library.delete(entry.slug);
                    onUpdated(await library.list());
                  },
                ),
              ],
            ),
          ),
        ElevatedButton(
          onPressed: () => _showEntryEditor(library: library, currentEntries: entries, onUpdated: onUpdated),
          child: const Text('Add'),
        ),
      ],
    );
  }
```

In `build()`, before the final `ElevatedButton(onPressed: _save, ...)` in the `ListView`'s `children`, add:

```dart
          _instructionSection(
            title: 'Skills',
            library: _skillsLibrary,
            entries: _skills,
            onUpdated: (updated) => setState(() => _skills = updated),
          ),
          _instructionSection(
            title: 'Personas',
            library: _personasLibrary,
            entries: _personas,
            onUpdated: (updated) => setState(() => _personas = updated),
          ),
          if (_personasLibrary != null) ...[
            const SizedBox(height: 8),
            DropdownButton<String?>(
              value: _agentConfig.defaultPersonaSlug,
              hint: const Text('Default persona'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None')),
                for (final p in _personas) DropdownMenuItem<String?>(value: p.slug, child: Text(p.name)),
              ],
              onChanged: (slug) => setState(() {
                _agentConfig = _agentConfig.copyWith(defaultPersonaSlug: slug, clearPersona: slug == null);
              }),
            ),
          ],
          const SizedBox(height: 24),
          const Text('Guardrails', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            controller: _guardrailsController,
            decoration: const InputDecoration(hintText: 'One rule per line, always applied'),
            maxLines: 4,
          ),
```

`DropdownButton` selecting "None" must also persist immediately into `_agentConfig` — the `onChanged` above already does this in memory; the persona default is written to disk by the existing `_save()` button along with everything else (Step 3 already saves `_agentConfig`). Extend `_save()`'s `updatedAgentConfig` line to also carry the persona slug:

```dart
    final updatedAgentConfig = _agentConfig.copyWith(guardrails: _guardrailsController.text);
```

This already preserves `_agentConfig.defaultPersonaSlug` because `copyWith` falls back to `this.defaultPersonaSlug` when not overridden — no further change needed.

- [ ] **Step 6: Dispose the new controller**

Add to the existing `dispose()` (create one if it doesn't exist yet — check first):

```dart
  @override
  void dispose() {
    _guardrailsController.dispose();
    super.dispose();
  }
```

- [ ] **Step 7: Verify statically**

Run: `flutter analyze lib/ui/settings_screen.dart`
Expected: "No issues found!" (pre-existing `RadioListTile` info-level deprecation notices are fine, per `implementation.md`)

- [ ] **Step 8: Commit**

```bash
git add lib/ui/settings_screen.dart
git commit -m "feat: add Skills, Personas, and Guardrails sections to Settings"
```

---

### Task 7: Chat screen — wire slash commands and prompt composition

**Files:**
- Modify: `lib/ui/chat_screen.dart`

**Interfaces:**
- Consumes: `parseSlashCommand`, `SkillCommand`, `PersonaCommand` (Task 4); `InstructionLibrary` (Task 1); `AgentConfig` (Task 2); `buildStructuringPrompt`'s new params (Task 5).

No unit tests — `chat_screen.dart` has none today, same rationale as Task 6. Verify via `flutter analyze` and a manual on-device smoke test (send `/persona:code-reviewer`, then `/some-unknown-skill`, then a normal refinement, confirm chat messages and generation match the spec).

- [ ] **Step 1: Add imports and new state**

```dart
// add to imports
import '../chat/slash_command.dart';
import '../instructions/instruction_library.dart';
import '../settings/agent_config.dart';
```

In `_ChatScreenState`, add fields:

```dart
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  AgentConfig _agentConfig = const AgentConfig();
  String? _activePersonaSlug; // session-local override; never persisted
  String? _pendingSkillSlug;  // one-time, cleared after next generation
```

- [ ] **Step 2: Load libraries and AgentConfig in `_init()`**

At the top of `_init()`, before `_structureRules` is computed, add:

```dart
    final docs = await getApplicationDocumentsDirectory();
    _skillsLibrary = InstructionLibrary(root: Directory('${docs.path}/skills'));
    _personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
    _agentConfig = await AgentConfig.load(prefs);
    _activePersonaSlug = _agentConfig.defaultPersonaSlug;
```

Add the `path_provider` import if not already present:

```dart
import 'package:path_provider/path_provider.dart';
```

- [ ] **Step 3: Handle slash commands in `_send()` before existing logic**

Replace `_send()`'s body with:

```dart
  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();

    final command = parseSlashCommand(text);
    if (command != null) {
      _handleSlashCommand(command, text);
      return;
    }

    final looksLikePathInstruction =
        RegExp(r'\b(save|put|store|write)\b', caseSensitive: false).hasMatch(text);
    final resolved = looksLikePathInstruction
        ? resolveSavePath(instruction: text, sourceRelativePath: widget.sourceRelativePath)
        : null;
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
      if (_engine == null) {
        setState(() => _messages.add(const _ChatMessage(
              'No LLM configured. Go to Settings and set up a Cloud API or On-device engine first.',
              fromUser: false,
            )));
      } else {
        _generate();
      }
    }
  }

  Future<void> _handleSlashCommand(SlashCommand command, String rawText) async {
    setState(() => _messages.add(_ChatMessage(rawText, fromUser: true)));

    if (command is SkillCommand) {
      final content = await _skillsLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _messages.add(_ChatMessage('No skill named "${command.slug}".', fromUser: false)));
        return;
      }
      _pendingSkillSlug = command.slug;
      setState(() => _messages.add(_ChatMessage('Applying skill "${command.slug}" to the next generation.', fromUser: false)));
      if (_engine != null) await _generate();
      return;
    }

    if (command is PersonaCommand) {
      final content = await _personasLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _messages.add(_ChatMessage('No persona named "${command.slug}".', fromUser: false)));
        return;
      }
      setState(() {
        _activePersonaSlug = command.slug;
        _messages.add(_ChatMessage('Persona switched to "${command.slug}" for this session.', fromUser: false));
      });
    }
  }
```

- [ ] **Step 4: Compose guardrails/persona/skill content in `_generate()`**

Modify `_generate()`'s prompt-building block:

```dart
  Future<void> _generate() async {
    if (_engine == null) return;
    setState(() => _busy = true);
    try {
      String? personaContent;
      if (_activePersonaSlug != null) {
        personaContent = await _personasLibrary?.contentFor(_activePersonaSlug!);
        if (personaContent == null) _activePersonaSlug = null; // fail safe: deleted since selection
      }

      final skillContent =
          _pendingSkillSlug != null ? await _skillsLibrary?.contentFor(_pendingSkillSlug!) : null;
      _pendingSkillSlug = null; // one-time use, cleared regardless of hit/miss

      final prompt = buildStructuringPrompt(
        structureRules: _structureRules,
        sourceContent: widget.sourceContent,
        refinementRequests: _refinements,
        guardrails: _agentConfig.guardrails,
        personaContent: personaContent,
        skillContent: skillContent,
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
```

- [ ] **Step 5: Verify statically**

Run: `flutter analyze lib/ui/chat_screen.dart`
Expected: "No issues found!"

- [ ] **Step 6: Manual on-device smoke test**

Build and install per the existing device workflow (`bash android/gradlew assembleDebug`, `adb install -r ...`), open a file's chat screen with a configured engine, and confirm:
- `/persona:code-reviewer` → confirmation message, no regeneration.
- `/no-such-skill` → "No skill named..." error, no crash.
- A normal refinement message (no leading `/`) still works exactly as before.

- [ ] **Step 7: Commit**

```bash
git add lib/ui/chat_screen.dart
git commit -m "feat: wire slash commands and guardrails/persona/skill prompt composition into chat"
```

---

### Task 8: Chat screen — on-device model load elapsed-time indicator

**Files:**
- Modify: `lib/ui/chat_screen.dart`

**Interfaces:**
- Consumes: `OnDeviceLlamaEngine` (existing, `lib/engine/on_device_llama_engine.dart`) — only used for an `is` type check, no changes to that class.

Not unit-tested — this is UI timing behavior, verified manually per the spec's Testing section. `dart:async`'s `Timer` needs no new dependency.

- [ ] **Step 1: Add imports and timer state**

```dart
// add to imports
import 'dart:async';
import '../engine/on_device_llama_engine.dart';
```

In `_ChatScreenState`:

```dart
  Timer? _loadTimer;
  int _loadElapsedSeconds = 0;
  bool _onDeviceModelLoaded = false;
```

- [ ] **Step 2: Start/stop the timer around the first on-device `generate()` call**

Modify `_generate()` to wrap the `_engine!.generate(prompt)` call:

```dart
  Future<void> _generate() async {
    if (_engine == null) return;
    final isFirstOnDeviceLoad = _engine is OnDeviceLlamaEngine && !_onDeviceModelLoaded;
    setState(() => _busy = true);
    if (isFirstOnDeviceLoad) {
      _loadElapsedSeconds = 0;
      _loadTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _loadElapsedSeconds++);
      });
    }
    try {
      String? personaContent;
      if (_activePersonaSlug != null) {
        personaContent = await _personasLibrary?.contentFor(_activePersonaSlug!);
        if (personaContent == null) _activePersonaSlug = null;
      }

      final skillContent =
          _pendingSkillSlug != null ? await _skillsLibrary?.contentFor(_pendingSkillSlug!) : null;
      _pendingSkillSlug = null;

      final prompt = buildStructuringPrompt(
        structureRules: _structureRules,
        sourceContent: widget.sourceContent,
        refinementRequests: _refinements,
        guardrails: _agentConfig.guardrails,
        personaContent: personaContent,
        skillContent: skillContent,
      );
      final result = await _engine!.generate(prompt);
      if (isFirstOnDeviceLoad) _onDeviceModelLoaded = true;
      setState(() {
        _latestStructuredContent = result;
        _messages.add(_ChatMessage(result, fromUser: false));
      });
    } catch (e) {
      setState(() => _messages.add(_ChatMessage('Generation failed: $e', fromUser: false)));
    } finally {
      _loadTimer?.cancel();
      _loadTimer = null;
      setState(() => _busy = false);
    }
  }
```

- [ ] **Step 3: Cancel the timer on screen disposal**

Modify the existing `dispose()`:

```dart
  @override
  void dispose() {
    _loadTimer?.cancel();
    _inputController.dispose();
    super.dispose();
  }
```

- [ ] **Step 4: Show the elapsed-time indicator instead of the generic progress bar while loading**

Replace `if (_busy) const LinearProgressIndicator(),` in `build()` with:

```dart
          if (_busy && _loadTimer != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Loading model… ${_loadElapsedSeconds}s'),
            )
          else if (_busy)
            const LinearProgressIndicator(),
```

- [ ] **Step 5: Verify statically**

Run: `flutter analyze lib/ui/chat_screen.dart`
Expected: "No issues found!"

- [ ] **Step 6: Manual on-device smoke test**

With an on-device `.gguf` model configured in Settings, open the chat screen for a file and confirm "Loading model… Ns" is shown counting up during the first generation, then disappears once the result arrives (or a second refinement's busy state shows the plain progress bar instead, since the model is already loaded).

- [ ] **Step 7: Run the full test suite**

Run: `flutter test`
Expected: PASS, all tests including the pre-existing 23 plus the new ones from Tasks 1, 2, 3, 4, 5.

- [ ] **Step 8: Commit**

```bash
git add lib/ui/chat_screen.dart
git commit -m "feat: show elapsed-time indicator while the on-device model loads"
```

---

## Post-plan: docs sync

After all 8 tasks are implemented and reviewed, update (outside this plan's task list, as an `implementation.md` change-log entry per the existing convention):
- `docs/implementation.md` — task-by-task summary table for this plan, plus any deviations found during execution.
- `docs/status_open_points.md` — move "Skills/personas/guardrails" from "actively spec'd" to "implemented"; remove the now-resolved "percentage loading screen" ask (replaced by the elapsed-time indicator) from Risks if no longer relevant.
- `docs/decision.md` — only if execution surfaces a real deviation from this plan (e.g. another library swap or API mismatch), following the established pattern.
