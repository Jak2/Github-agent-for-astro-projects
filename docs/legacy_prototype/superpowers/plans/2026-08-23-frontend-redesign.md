# Frontend Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild git_agent_app's UI to match the mockup at `fronten/Git Agent App Design/git_agent_app.dc.html` — black/white visual system, bottom-tab navigation (Chat/GitHub/Config), a one-time onboarding wizard, and a flat-state-machine GitHub tab — while reusing all existing backend logic unchanged.

**Architecture:** A shared `lib/theme/app_theme.dart` module supplies colors, text styles (Sora/Inter/JetBrains Mono via `google_fonts`), and reusable styled widgets (bordered text field, primary/secondary button, chat bubble) that every new screen composes. `main.dart` routes to `OnboardingScreen` (if not yet onboarded) or `RootScreen` (a 3-tab `IndexedStack`: `GeneralChatScreen`, `GithubTabScreen`, `ConfigScreen`). `GithubTabScreen` replaces `RepoListScreen`/`FileBrowserScreen`/`ChatScreen`'s `Navigator.push` chain with one `StatefulWidget` holding `_subScreen` state (`repos | files | chat`) and back buttons that just change that state, folding in all three screens' existing logic verbatim. `ConfigScreen` replaces `SettingsScreen` with the same fields, restyled, plus two inert LangChain/LangGraph toggle switches.

**Tech Stack:** Flutter/Dart, new dependency `google_fonts` (Sora/Inter/JetBrains Mono are Google Fonts, unavailable as a network `<link>` in a native app). No other new dependencies — all backend logic (`InstructionLibrary`, `AgentConfig`, `EngineSettings`, `SecretStore`, `RepoGitService`, `buildStructuringPrompt`, slash-command parsing) is reused unchanged.

## Global Constraints

- Visual system app-wide: black (`#000`) background, white (`#fff`) 2-3px borders, hard offset drop-shadows on primary buttons, `Sora` (headings), `Inter` (body/UI), `JetBrains Mono` (paths/code/technical labels).
- General "Chat" tab is a stub: static assistant message + input that always replies with a canned redirect message. No LLM call.
- LangChain/LangGraph toggles are inert UI: no persistence, no backend, matching the mockup exactly. This is a deliberate, approved exception to decision.md #12.
- GitHub tab is a flat state machine: one widget, `_subScreen` state (`repos | files | chat`), explicit back buttons that set `_subScreen` — not `Navigator.push` between routes.
- Onboarding is one-time, gated by a persisted `onboarded: bool` (SharedPreferences, default `false`), and writes to the same `SecretStore`/`EngineSettings` the Config tab uses — not a separate store.
- No changes to `InstructionLibrary`, `AgentConfig`, `EngineSettings`, `SecretStore`, `RepoGitService`, `buildStructuringPrompt`, `parseSlashCommand`, or any other existing non-UI file's logic.
- Phone-portrait only, matching the mockup and the app's existing scope. No tablet/landscape layout.
- These UI screens have no unit tests in this codebase (existing convention — `chat_screen.dart`, `settings_screen.dart`, `repo_list_screen.dart`, `file_browser_screen.dart` all have zero). Verify each task with `flutter analyze`, not new test files. `lib/theme/app_theme.dart` is pure declarative styling with no branching logic — also no test.
- The `flutter` command is not on PATH in the execution environment. Use the full path: `/home/asterisk/develop/flutter/bin/flutter`.

---

### Task 1: Theme foundation

**Files:**
- Create: `lib/theme/app_theme.dart`
- Modify: `pubspec.yaml` (add `google_fonts` dependency)
- Modify: `lib/main.dart` (apply theme to `MaterialApp`)

**Interfaces:**
- Produces:
  - `class AppColors { static const Color bg; static const Color fg; static const Color muted; static const Color divider; static const Color surfaceMuted; }`
  - `TextStyle appHeading({double size = 24, FontWeight weight = FontWeight.w800})`
  - `TextStyle appBody({double size = 13.5, Color? color, FontWeight weight = FontWeight.w400})`
  - `TextStyle appMono({double size = 13, Color? color, FontWeight weight = FontWeight.w400})`
  - `ThemeData appThemeData()`
  - `Widget appBorderedField({required TextEditingController controller, required String hint, bool obscure = false, int maxLines = 1, TextInputType? keyboardType})`
  - `Widget appPrimaryButton({required String label, required VoidCallback? onPressed})`
  - `Widget appSecondaryButton({required String label, required VoidCallback? onPressed})`
  - `Widget appChatBubble({required String text, required bool fromUser, bool mono = false})`
  - `Widget appIconCircleButton({required IconData icon, required VoidCallback? onPressed, bool filled = false})`

- [ ] **Step 1: Add the dependency**

Edit `pubspec.yaml`'s `dependencies:` block, adding this line alongside the existing entries (anywhere in the list, e.g. after `llama_cpp_dart: ^0.0.9`):

```yaml
  google_fonts: ^6.2.1
```

Run: `/home/asterisk/develop/flutter/bin/flutter pub get`
Expected: completes with no errors.

- [ ] **Step 2: Write the theme module**

```dart
// lib/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const Color bg = Colors.black;
  static const Color fg = Colors.white;
  static const Color muted = Color(0xFF888888);
  static const Color divider = Color(0xFF333333);
  static const Color surfaceMuted = Color(0xFF111111);
}

TextStyle appHeading({double size = 24, FontWeight weight = FontWeight.w800}) {
  return GoogleFonts.sora(fontSize: size, fontWeight: weight, color: AppColors.fg);
}

TextStyle appBody({double size = 13.5, Color? color, FontWeight weight = FontWeight.w400}) {
  return GoogleFonts.inter(fontSize: size, fontWeight: weight, color: color ?? AppColors.fg);
}

TextStyle appMono({double size = 13, Color? color, FontWeight weight = FontWeight.w400}) {
  return GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: weight, color: color ?? AppColors.fg);
}

ThemeData appThemeData() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: GoogleFonts.inter().fontFamily,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.bg,
      primary: AppColors.fg,
      onPrimary: AppColors.bg,
    ),
    dividerColor: AppColors.divider,
  );
}

Widget appBorderedField({
  required TextEditingController controller,
  required String hint,
  bool obscure = false,
  int maxLines = 1,
  TextInputType? keyboardType,
}) {
  return TextField(
    controller: controller,
    obscureText: obscure,
    maxLines: maxLines,
    keyboardType: keyboardType,
    style: appMono(size: 13),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: appMono(size: 13, color: AppColors.muted),
      filled: true,
      fillColor: AppColors.bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.fg, width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.fg, width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.fg, width: 2),
      ),
    ),
  );
}

Widget appPrimaryButton({required String label, required VoidCallback? onPressed}) {
  return SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.fg,
        foregroundColor: AppColors.bg,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
        elevation: 0,
      ),
      child: Text(label, style: GoogleFonts.sora(fontWeight: FontWeight.w700, fontSize: 15)),
    ),
  );
}

Widget appSecondaryButton({required String label, required VoidCallback? onPressed}) {
  return SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.fg,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
      ),
      child: Text(label, style: appBody(size: 14, weight: FontWeight.w600)),
    ),
  );
}

Widget appChatBubble({required String text, required bool fromUser, bool mono = false}) {
  final style = fromUser
      ? appBody(size: 13.5, color: AppColors.bg)
      : (mono ? appMono(size: 12, color: AppColors.fg) : appBody(size: 13.5, color: AppColors.fg));
  return Align(
    alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 320),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: fromUser ? AppColors.fg : AppColors.bg,
        border: Border.all(color: AppColors.fg, width: 2),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(fromUser ? 14 : 3),
          bottomRight: Radius.circular(fromUser ? 3 : 14),
        ),
      ),
      child: Text(text, style: style),
    ),
  );
}

Widget appIconCircleButton({required IconData icon, required VoidCallback? onPressed, bool filled = false}) {
  return SizedBox(
    width: 40,
    height: 40,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: filled ? AppColors.fg : AppColors.bg,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
      ),
      child: Icon(icon, size: 18, color: filled ? AppColors.bg : AppColors.fg),
    ),
  );
}
```

- [ ] **Step 3: Apply the theme in `main.dart`**

In `lib/main.dart`, add the import and pass the theme to `MaterialApp`:

```dart
import 'theme/app_theme.dart';
```

Change:

```dart
    return MaterialApp(
      title: 'git_agent_app',
      home: HomeScreen(secretStore: secretStore),
    );
```

to:

```dart
    return MaterialApp(
      title: 'git_agent_app',
      theme: appThemeData(),
      home: HomeScreen(secretStore: secretStore),
    );
```

(`HomeScreen` is replaced in Task 3 — leave it as-is for now so the app still builds after this task.)

- [ ] **Step 4: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze`
Expected: no new issues beyond the pre-existing 4 `RadioListTile` deprecation infos.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/theme/app_theme.dart lib/main.dart
git commit -m "feat: add black/white theme foundation with google_fonts"
```

---

### Task 2: Onboarding wizard

**Files:**
- Create: `lib/ui/onboarding_screen.dart`

**Interfaces:**
- Consumes: `AppColors`, `appHeading`, `appBody`, `appMono`, `appBorderedField`, `appPrimaryButton` (Task 1); `SecretStore`, `secretKeyGithubPat` (`lib/secrets/secret_store.dart`); `EngineSettings`, `EngineChoice` (`lib/settings/engine_settings.dart`); `GithubApi`, `GithubRepo` (`lib/github/github_api.dart`, `lib/github/github_repo.dart`).
- Produces: `class OnboardingScreen extends StatefulWidget { final SecretStore secretStore; final VoidCallback onFinished; const OnboardingScreen({super.key, required this.secretStore, required this.onFinished}); }`

`onFinished` is called once the wizard completes or is skipped past its last step — the caller (Task 3) is responsible for persisting the `onboarded` flag and swapping to `RootScreen`; this widget only signals "done."

- [ ] **Step 1: Write the onboarding screen**

```dart
// lib/ui/onboarding_screen.dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../github/github_api.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  final SecretStore secretStore;
  final VoidCallback onFinished;

  const OnboardingScreen({super.key, required this.secretStore, required this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { pat, reposIntro, llm }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.pat;
  bool _reposPreviewOpen = false;

  final _patController = TextEditingController();
  final _endpointController = TextEditingController(text: 'https://api.openai.com/v1/chat/completions');
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController(text: 'gpt-4o-mini');
  final _headersController = TextEditingController();
  EngineChoice _engineChoice = EngineChoice.cloud;
  String _onDeviceModelPath = '';

  List<GithubRepo>? _previewRepos;
  String? _previewError;

  @override
  void dispose() {
    _patController.dispose();
    _endpointController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _headersController.dispose();
    super.dispose();
  }

  Future<void> _openReposPreview() async {
    setState(() {
      _reposPreviewOpen = true;
      _previewRepos = null;
      _previewError = null;
    });
    try {
      final api = GithubApi(client: Dio(), token: _patController.text);
      final repos = await api.listRepos();
      if (mounted) setState(() => _previewRepos = repos);
    } catch (e) {
      if (mounted) setState(() => _previewError = 'Failed to load repos: $e');
    }
  }

  Future<void> _pickOnDeviceModel() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path != null) setState(() => _onDeviceModelPath = path);
  }

  Future<void> _next() async {
    if (_step == _Step.llm) {
      await _persistAndFinish();
      return;
    }
    setState(() => _step = _Step.values[_step.index + 1]);
  }

  Future<void> _skip() => _persistAndFinish();

  Future<void> _persistAndFinish() async {
    await widget.secretStore.write(secretKeyGithubPat, _patController.text);
    final prefs = await SharedPreferences.getInstance();
    final settings = EngineSettings(
      choice: _engineChoice,
      cloudEndpoint: _endpointController.text,
      cloudModel: _modelController.text,
      cloudHeaders: _headersController.text,
      onDeviceModelPath: _onDeviceModelPath,
    );
    await settings.save(prefs);
    if (_engineChoice == EngineChoice.cloud) {
      await widget.secretStore.write(secretKeyCloudApiKey, _apiKeyController.text);
    }
    widget.onFinished();
  }

  Widget _dots() {
    return Row(
      children: [
        for (var i = 0; i < _Step.values.length; i++)
          Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i == _Step.values.length - 1 ? 0 : 10),
              decoration: BoxDecoration(
                color: i <= _step.index ? AppColors.fg : AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    );
  }

  Widget _stepLabel(String text) => Text(
        text,
        style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 1.5),
      );

  Widget _patStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepLabel('STEP 1 OF 3'),
          const SizedBox(height: 16),
          Text('Connect GitHub', style: appHeading()),
          const SizedBox(height: 16),
          Text(
            'Paste a Personal Access Token with repo scope. Generate one at github.com/settings/tokens.',
            style: appBody(size: 13.5, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          appBorderedField(controller: _patController, hint: 'ghp_xxxxxxxxxxxx', obscure: true),
        ],
      ),
    );
  }

  Widget _reposIntroStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepLabel('STEP 2 OF 3'),
          const SizedBox(height: 16),
          Text('Your repositories', style: appHeading()),
          const SizedBox(height: 16),
          Text(
            "Take a look at what's on your GitHub account, or skip for now.",
            style: appBody(size: 13.5, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          appSecondaryButton(label: 'Browse your repositories', onPressed: _openReposPreview),
        ],
      ),
    );
  }

  Widget _llmStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepLabel('STEP 3 OF 3'),
          const SizedBox(height: 16),
          Text('Choose your LLM', style: appHeading()),
          const SizedBox(height: 14),
          RadioListTile<EngineChoice>(
            contentPadding: EdgeInsets.zero,
            title: Text('Cloud API', style: appBody(size: 14.5)),
            value: EngineChoice.cloud,
            groupValue: _engineChoice,
            onChanged: (v) => setState(() => _engineChoice = v!),
          ),
          if (_engineChoice == EngineChoice.cloud)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 8),
              child: Column(
                children: [
                  appBorderedField(controller: _endpointController, hint: 'Endpoint URL'),
                  const SizedBox(height: 8),
                  appBorderedField(controller: _apiKeyController, hint: 'API key', obscure: true),
                  const SizedBox(height: 8),
                  appBorderedField(controller: _modelController, hint: 'Model name (optional)'),
                  const SizedBox(height: 8),
                  appBorderedField(controller: _headersController, hint: 'Extra headers (Name: value per line)', maxLines: 2),
                ],
              ),
            ),
          RadioListTile<EngineChoice>(
            contentPadding: EdgeInsets.zero,
            title: Text('On-device (.gguf)', style: appBody(size: 14.5)),
            value: EngineChoice.onDevice,
            groupValue: _engineChoice,
            onChanged: (v) => setState(() => _engineChoice = v!),
          ),
          if (_engineChoice == EngineChoice.onDevice)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _onDeviceModelPath.isEmpty ? 'No model selected' : _onDeviceModelPath,
                      style: appMono(size: 11.5, color: AppColors.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  appSecondaryButton(label: 'Choose file', onPressed: _pickOnDeviceModel),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _reposPreviewOverlay() {
    return Positioned.fill(
      child: Container(
        color: AppColors.bg,
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  appIconCircleButton(
                    icon: Icons.arrow_back,
                    onPressed: () => setState(() => _reposPreviewOpen = false),
                  ),
                  const SizedBox(width: 12),
                  Text('Your repositories', style: appHeading(size: 17, weight: FontWeight.w700)),
                ],
              ),
            ),
            const Divider(color: AppColors.fg, thickness: 2, height: 2),
            Expanded(
              child: _previewError != null
                  ? Center(child: Text(_previewError!, style: appBody(color: AppColors.muted)))
                  : _previewRepos == null
                      ? const Center(child: CircularProgressIndicator(color: AppColors.fg))
                      : ListView(
                          children: [
                            for (final r in _previewRepos!)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                decoration: const BoxDecoration(
                                  border: Border(bottom: BorderSide(color: AppColors.divider, width: 2)),
                                ),
                                child: Text(r.fullName, style: appMono(size: 13)),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: _dots(),
                ),
                Expanded(
                  child: Center(
                    child: switch (_step) {
                      _Step.pat => _patStep(),
                      _Step.reposIntro => _reposIntroStep(),
                      _Step.llm => _llmStep(),
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                  child: Column(
                    children: [
                      appPrimaryButton(
                        label: _step == _Step.llm ? 'Finish setup' : 'Next',
                        onPressed: _next,
                      ),
                      if (_step == _Step.reposIntro)
                        TextButton(
                          onPressed: _skip,
                          child: Text('Skip', style: appBody(size: 13, color: AppColors.muted)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_reposPreviewOpen) _reposPreviewOverlay(),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze lib/ui/onboarding_screen.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add lib/ui/onboarding_screen.dart
git commit -m "feat: add onboarding wizard screen"
```

---

### Task 3: RootScreen with bottom-tab navigation, wired into main.dart

**Files:**
- Create: `lib/ui/root_screen.dart`
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `OnboardingScreen` (Task 2); `AppColors`, `appMono` (Task 1); `GeneralChatScreen` (Task 4, forward reference — this task's `RootScreen` imports it but Task 4 creates the file); `GithubTabScreen` (Task 5, forward reference); `ConfigScreen` (Task 7, forward reference).
- Produces: `class RootScreen extends StatefulWidget { final SecretStore secretStore; const RootScreen({super.key, required this.secretStore}); }`

This task creates placeholder stub files for `GeneralChatScreen`, `GithubTabScreen`, and `ConfigScreen` so the app compiles — later tasks (4, 5, 7) replace the placeholders with real implementations. This ordering lets `flutter analyze` pass at every commit.

- [ ] **Step 1: Create placeholder screens (temporary, replaced by Tasks 4, 5, 7)**

```dart
// lib/ui/general_chat_screen.dart
import 'package:flutter/material.dart';

class GeneralChatScreen extends StatelessWidget {
  const GeneralChatScreen({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
```

```dart
// lib/ui/github_tab_screen.dart
import 'package:flutter/material.dart';
import '../secrets/secret_store.dart';

class GithubTabScreen extends StatelessWidget {
  final SecretStore secretStore;
  const GithubTabScreen({super.key, required this.secretStore});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
```

Leave `lib/ui/config_screen.dart` uncreated for now — Task 7 creates it directly as the real implementation, and this task's `RootScreen` imports it by name (the import will fail to resolve until Task 7 lands, so **Task 7 must be completed before `flutter analyze` on the whole project is clean** — that's fine, each task's own file still analyzes cleanly in isolation; the plan sequences tasks so `RootScreen` is functionally complete only once Tasks 4, 5, and 7 have all landed).

- [ ] **Step 2: Write RootScreen**

```dart
// lib/ui/root_screen.dart
import 'package:flutter/material.dart';
import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';
import 'config_screen.dart';
import 'general_chat_screen.dart';
import 'github_tab_screen.dart';

class RootScreen extends StatefulWidget {
  final SecretStore secretStore;
  const RootScreen({super.key, required this.secretStore});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [
      const GeneralChatScreen(),
      GithubTabScreen(secretStore: widget.secretStore),
      ConfigScreen(secretStore: widget.secretStore),
    ];
    final navItems = [
      (icon: Icons.chat_bubble_outline, label: 'Chat'),
      (icon: Icons.hub_outlined, label: 'GitHub'),
      (icon: Icons.tune, label: 'Config'),
    ];

    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: tabs),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.fg, width: 2)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              for (var i = 0; i < navItems.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _tabIndex = i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            navItems[i].icon,
                            size: 21,
                            color: _tabIndex == i ? AppColors.fg : AppColors.muted,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            navItems[i].label,
                            style: appMono(size: 10, color: _tabIndex == i ? AppColors.fg : AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Wire onboarding gating into `main.dart`**

Replace the whole content of `lib/main.dart` with:

```dart
// lib/main.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:git2dart/git2dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'instructions/instruction_library.dart';
import 'instructions/starter_personas.dart';
import 'secrets/secret_store.dart';
import 'theme/app_theme.dart';
import 'ui/onboarding_screen.dart';
import 'ui/root_screen.dart';

const _keyOnboarded = 'onboarded';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PlatformSpecific.initialize();
  final docs = await getApplicationDocumentsDirectory();
  final personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
  await seedStarterPersonasIfEmpty(personasLibrary, rootBundle.loadString);
  runApp(const GitAgentApp());
}

class GitAgentApp extends StatelessWidget {
  const GitAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    final secretStore = SecureSecretStore();
    return MaterialApp(
      title: 'git_agent_app',
      theme: appThemeData(),
      home: _AppEntry(secretStore: secretStore),
    );
  }
}

class _AppEntry extends StatefulWidget {
  final SecretStore secretStore;
  const _AppEntry({required this.secretStore});

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool? _onboarded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _onboarded = prefs.getBool(_keyOnboarded) ?? false);
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyOnboarded, true);
    if (mounted) setState(() => _onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarded == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_onboarded!) {
      return OnboardingScreen(secretStore: widget.secretStore, onFinished: _finishOnboarding);
    }
    return RootScreen(secretStore: widget.secretStore);
  }
}
```

This removes `HomeScreen` entirely — it's superseded by `RootScreen`.

- [ ] **Step 4: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze`
Expected: errors about `config_screen.dart` not existing yet (Task 7 creates it) — this is expected at this point in the plan. Confirm there are no OTHER errors by running:

`/home/asterisk/develop/flutter/bin/flutter analyze lib/ui/root_screen.dart lib/main.dart lib/ui/general_chat_screen.dart lib/ui/github_tab_screen.dart 2>&1 | grep -v config_screen`

Expected: no output (no issues outside the expected missing-file errors).

- [ ] **Step 5: Commit**

```bash
git add lib/ui/root_screen.dart lib/ui/general_chat_screen.dart lib/ui/github_tab_screen.dart lib/main.dart
git commit -m "feat: add RootScreen with bottom-tab navigation and onboarding gate"
```

---

### Task 4: General Chat tab (stub)

**Files:**
- Modify: `lib/ui/general_chat_screen.dart` (replaces the Task 3 placeholder)

**Interfaces:**
- Consumes: `AppColors`, `appHeading`, `appBorderedField`, `appChatBubble`, `appIconCircleButton` (Task 1).
- Produces: same `GeneralChatScreen` public shape as the placeholder (`StatelessWidget` → now `StatefulWidget`, but still `const GeneralChatScreen({super.key})` — no required params, so `RootScreen`'s call site in Task 3 needs no change).

- [ ] **Step 1: Write the real stub chat screen**

```dart
// lib/ui/general_chat_screen.dart
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class _Message {
  final String text;
  final bool fromUser;
  const _Message(this.text, {required this.fromUser});
}

class GeneralChatScreen extends StatefulWidget {
  const GeneralChatScreen({super.key});

  @override
  State<GeneralChatScreen> createState() => _GeneralChatScreenState();
}

class _GeneralChatScreenState extends State<GeneralChatScreen> {
  final List<_Message> _messages = [
    const _Message(
      'Ask me anything about your repos, or open a file from the GitHub tab to structure it.',
      fromUser: false,
    ),
  ];
  final _inputController = TextEditingController();

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() {
      _messages.add(_Message(text, fromUser: true));
      _messages.add(const _Message(
        'Open a file from the GitHub tab to generate structured Markdown from it.',
        fromUser: false,
      ));
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 60,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text('Assistant', style: appHeading(size: 17, weight: FontWeight.w700)),
              ],
            ),
          ),
          const Divider(color: AppColors.fg, thickness: 2, height: 2),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final m = _messages[index];
                return appChatBubble(text: m.text, fromUser: m.fromUser);
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
                    hint: 'Ask the assistant, or /skill-name, /persona:name',
                  ),
                ),
                const SizedBox(width: 8),
                appIconCircleButton(icon: Icons.arrow_forward, onPressed: _send, filled: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze lib/ui/general_chat_screen.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add lib/ui/general_chat_screen.dart
git commit -m "feat: implement stub general assistant chat tab"
```

---

### Task 5: GitHub tab — repos and files sub-screens

**Files:**
- Modify: `lib/ui/github_tab_screen.dart` (replaces the Task 3 placeholder; Task 6 extends this same file with the chat sub-screen)
- Delete: `lib/ui/repo_list_screen.dart`
- Delete: `lib/ui/file_browser_screen.dart`

**Interfaces:**
- Consumes: `AppColors`, `appHeading`, `appMono`, `appIconCircleButton` (Task 1); `RepoGitService`, `repoDirectory` (`lib/git/repo_git_service.dart`, `lib/git/repo_paths.dart`); `GithubApi`, `GithubRepo` (`lib/github/`); `buildFileTree`, `FileTreeNode` (`lib/files/file_tree.dart`); `secretKeyGithubPat` (`lib/secrets/secret_store.dart`).
- Produces: `class GithubTabScreen extends StatefulWidget` — same public shape as the Task 3 placeholder (`{final SecretStore secretStore; const GithubTabScreen({super.key, required this.secretStore});}`), so `RootScreen`'s call site needs no change. Internal `_GithubTabScreenState` holds `_subScreen` (`_SubScreen.repos | files | chat`) — Task 6 adds the `chat` case's body to this same state class.

This task folds `RepoListScreen`'s and `FileBrowserScreen`'s existing logic (clone/already-cloned detection, file-tree browsing) into one widget's state, replacing their `Navigator.push` calls with `setState` transitions. The chat sub-screen is stubbed as a placeholder `Container` here — Task 6 fills it in — so this task is independently reviewable and the file still compiles.

- [ ] **Step 1: Write the repos + files portion of the combined screen**

```dart
// lib/ui/github_tab_screen.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../files/file_tree.dart';
import '../git/repo_git_service.dart';
import '../git/repo_paths.dart';
import '../github/github_api.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';

enum _SubScreen { repos, files, chat }

class GithubTabScreen extends StatefulWidget {
  final SecretStore secretStore;
  const GithubTabScreen({super.key, required this.secretStore});

  @override
  State<GithubTabScreen> createState() => _GithubTabScreenState();
}

class _GithubTabScreenState extends State<GithubTabScreen> {
  _SubScreen _subScreen = _SubScreen.repos;

  // --- repos state ---
  List<GithubRepo>? _repos;
  String? _reposError;
  String? _cloningFullName;
  Directory? _reposRoot;
  Set<String> _alreadyClonedFullNames = {};

  // --- files state ---
  GithubRepo? _activeRepo;
  Directory? _activeRepoDir;
  FileTreeNode? _fileRoot;

  // --- chat state (populated in Task 6) ---
  String? _activeFilePath;
  String? _activeFileContent;

  @override
  void initState() {
    super.initState();
    _loadRepos();
  }

  Future<void> _loadRepos() async {
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null || token.isEmpty) {
      setState(() => _reposError = 'Add a GitHub Personal Access Token in Config first.');
      return;
    }
    try {
      final api = GithubApi(client: Dio(), token: token);
      final repos = await api.listRepos();
      final reposRoot = await getApplicationDocumentsDirectory();
      final alreadyCloned = <String>{};
      for (final repo in repos) {
        final dir = await repoDirectory(reposRoot, repo.fullName);
        if (await dir.exists()) alreadyCloned.add(repo.fullName);
      }
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _reposRoot = reposRoot;
        _alreadyClonedFullNames = alreadyCloned;
      });
    } catch (e) {
      if (mounted) setState(() => _reposError = 'Failed to load repos: $e');
    }
  }

  Future<void> _openRepo(GithubRepo repo, Directory dir) async {
    final tree = await buildFileTree(dir);
    if (!mounted) return;
    setState(() {
      _activeRepo = repo;
      _activeRepoDir = dir;
      _fileRoot = tree;
      _subScreen = _SubScreen.files;
    });
  }

  Future<void> _tapRepo(GithubRepo repo) async {
    if (_cloningFullName != null) return;
    final reposRoot = _reposRoot;
    if (_alreadyClonedFullNames.contains(repo.fullName) && reposRoot != null) {
      final dir = await repoDirectory(reposRoot, repo.fullName);
      await _openRepo(repo, dir);
      return;
    }
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('GitHub Personal Access Token missing. Add one in Config.'),
        ));
      }
      return;
    }
    setState(() => _cloningFullName = repo.fullName);
    try {
      final root = await getApplicationDocumentsDirectory();
      final service = RepoGitService(reposRoot: root);
      final dir = await service.cloneRepo(repo: repo, token: token);
      if (!mounted) return;
      setState(() => _alreadyClonedFullNames = {..._alreadyClonedFullNames, repo.fullName});
      await _openRepo(repo, dir);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Clone failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _cloningFullName = null);
    }
  }

  Future<void> _openFile(FileTreeNode node) async {
    final dir = _activeRepoDir;
    if (dir == null) return;
    String content;
    try {
      content = await File('${dir.path}/${node.relativePath}').readAsString();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read file: $e')));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _activeFilePath = node.relativePath;
      _activeFileContent = content;
      _subScreen = _SubScreen.chat;
    });
  }

  void _goBackToRepos() => setState(() => _subScreen = _SubScreen.repos);
  void _goBackToFiles() => setState(() => _subScreen = _SubScreen.files);

  Widget _reposBody() {
    if (_reposError != null) {
      return Center(child: Text(_reposError!, style: appBody(color: AppColors.muted)));
    }
    if (_repos == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.fg));
    }
    return ListView(
      children: [
        for (final r in _repos!)
          _RepoRow(
            repo: r,
            isCloning: _cloningFullName == r.fullName,
            isCloned: _alreadyClonedFullNames.contains(r.fullName) && _cloningFullName != r.fullName,
            onTap: _cloningFullName != null ? null : () => _tapRepo(r),
          ),
      ],
    );
  }

  List<Widget> _fileTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      tiles.add(InkWell(
        onTap: child.isDirectory ? null : () => _openFile(child),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16 + depth * 16.0, 10, 16, 10),
          child: Row(
            children: [
              Icon(
                child.isDirectory ? Icons.folder_outlined : Icons.description_outlined,
                size: 16,
                color: child.isDirectory ? AppColors.fg : AppColors.muted,
              ),
              const SizedBox(width: 10),
              Text(child.name, style: appMono(size: 13)),
            ],
          ),
        ),
      ));
      if (child.isDirectory) tiles.addAll(_fileTiles(child, depth + 1));
    }
    return tiles;
  }

  Widget _filesBody() {
    final root = _fileRoot;
    return Column(
      children: [
        SizedBox(
          height: 60,
          child: Row(
            children: [
              const SizedBox(width: 16),
              appIconCircleButton(icon: Icons.arrow_back, onPressed: _goBackToRepos),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _activeRepo?.fullName ?? '',
                  style: appMono(size: 14, weight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(color: AppColors.fg, thickness: 2, height: 2),
        Expanded(
          child: root == null
              ? const Center(child: CircularProgressIndicator(color: AppColors.fg))
              : ListView(children: _fileTiles(root, 0)),
        ),
      ],
    );
  }

  Widget _chatBody() {
    // Filled in by Task 6.
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_subScreen) {
        _SubScreen.repos => _reposBody(),
        _SubScreen.files => _filesBody(),
        _SubScreen.chat => _chatBody(),
      },
    );
  }
}

class _RepoRow extends StatelessWidget {
  final GithubRepo repo;
  final bool isCloning;
  final bool isCloned;
  final VoidCallback? onTap;

  const _RepoRow({required this.repo, required this.isCloning, required this.isCloned, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider, width: 2)),
        ),
        child: Row(
          children: [
            if (isCloning)
              const SizedBox(
                width: 36,
                height: 36,
                child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg))),
              )
            else
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.fg, width: 2),
                  borderRadius: BorderRadius.circular(10),
                  color: isCloned ? AppColors.fg : AppColors.bg,
                ),
                child: Icon(
                  isCloned ? Icons.folder_open : Icons.download,
                  size: 16,
                  color: isCloned ? AppColors.bg : AppColors.fg,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(repo.fullName, style: appMono(size: 13.5), overflow: TextOverflow.ellipsis),
                  if (isCloned)
                    Text('Already cloned — tap to open', style: appBody(size: 11, color: AppColors.muted)),
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

- [ ] **Step 2: Delete the superseded screens**

```bash
git rm my_learning_projects/git_agent_app/lib/ui/repo_list_screen.dart
git rm my_learning_projects/git_agent_app/lib/ui/file_browser_screen.dart
```

(Run from the repo root; adjust the leading path if already inside `my_learning_projects/git_agent_app`.)

- [ ] **Step 3: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze lib/ui/github_tab_screen.dart lib/ui/root_screen.dart lib/main.dart`
Expected: only the expected missing-`config_screen.dart` errors from Task 3 (Task 7 resolves those) and no other issues.

- [ ] **Step 4: Commit**

```bash
git add lib/ui/github_tab_screen.dart
git commit -m "feat: fold repo list and file browser into GithubTabScreen flat state machine"
```

---

### Task 6: GitHub tab — chat sub-screen

**Files:**
- Modify: `lib/ui/github_tab_screen.dart` (extends the Task 5 state with the real `_chatBody()`)
- Delete: `lib/ui/chat_screen.dart`

**Interfaces:**
- Consumes: everything `lib/ui/chat_screen.dart` currently consumes (`save_path_resolver.dart`, `slash_command.dart`, `structuring_prompt.dart`, `engine_factory.dart`, `llm_engine.dart`, `on_device_llama_engine.dart`, `instruction_library.dart`, `agent_config.dart`, `engine_settings.dart`) plus `AppColors`, `appMono`, `appBody`, `appBorderedField`, `appPrimaryButton`, `appChatBubble`, `appIconCircleButton` (Task 1).
- Produces: no new public API — `_chatBody()` becomes real, using `_GithubTabScreenState`'s existing `_activeFilePath`/`_activeFileContent`/`_activeRepoDir` fields from Task 5.

This task ports `ChatScreen`'s entire state machine (generation, slash commands, persona/skill/guardrails composition, on-device load timer, save-path resolution, folder-browse bottom sheet, push) into `_GithubTabScreenState`, scoped to the currently open file. The mockup's persona badge (`Persona: {name}`) and toast notifications are added as new UI elements this task introduces (the current `ChatScreen` shows neither) — everything else is a direct, restyled port of existing logic.

- [ ] **Step 1: Add chat state and logic to `_GithubTabScreenState`**

In `lib/ui/github_tab_screen.dart`, add these imports:

```dart
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import '../chat/save_path_resolver.dart';
import '../chat/slash_command.dart';
import '../chat/structuring_prompt.dart';
import '../engine/engine_factory.dart';
import '../engine/llm_engine.dart';
import '../engine/on_device_llama_engine.dart';
import '../instructions/instruction_library.dart';
import '../settings/agent_config.dart';
import '../settings/engine_settings.dart';
import '../secrets/secret_store.dart' show secretKeyCloudApiKey;
```

Add a private message class above `_SubScreen`:

```dart
class _ChatMessage {
  final String text;
  final bool fromUser;
  const _ChatMessage(this.text, {required this.fromUser});
}
```

Add these fields to `_GithubTabScreenState` (alongside the existing chat-state comment block from Task 5):

```dart
  final List<_ChatMessage> _chatMessages = [];
  final List<String> _refinements = [];
  final _chatInputController = TextEditingController();
  LlmEngine? _engine;
  String _structureRules = '';
  String? _latestStructuredContent;
  String? _resolvedSavePath;
  bool _chatBusy = false;
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  AgentConfig _agentConfig = const AgentConfig();
  String? _activePersonaSlug;
  String? _pendingSkillSlug;
  Timer? _loadTimer;
  int _loadElapsedSeconds = 0;
  bool _onDeviceModelLoaded = false;
  String? _toast;
  Timer? _toastTimer;
```

Add `_chatInputController.dispose()` and `_loadTimer?.cancel()` and `_toastTimer?.cancel()` via a `dispose()` override (this widget had no `dispose()` before Task 6 — add one now):

```dart
  @override
  void dispose() {
    _loadTimer?.cancel();
    _toastTimer?.cancel();
    _chatInputController.dispose();
    super.dispose();
  }
```

Replace `_openFile`'s body (written in Task 5) to also initialize chat state and kick off the first generation, by changing:

```dart
    if (!mounted) return;
    setState(() {
      _activeFilePath = node.relativePath;
      _activeFileContent = content;
      _subScreen = _SubScreen.chat;
    });
  }
```

to:

```dart
    if (!mounted) return;
    setState(() {
      _activeFilePath = node.relativePath;
      _activeFileContent = content;
      _chatMessages.clear();
      _refinements.clear();
      _latestStructuredContent = null;
      _resolvedSavePath = null;
      _activePersonaSlug = null;
      _pendingSkillSlug = null;
      _onDeviceModelLoaded = false;
      _subScreen = _SubScreen.chat;
    });
    await _initChat();
  }

  void _showToast(String message) {
    setState(() => _toast = message);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Future<void> _initChat() async {
    final prefs = await SharedPreferences.getInstance();
    final docs = await getApplicationDocumentsDirectory();
    _skillsLibrary = InstructionLibrary(root: Directory('${docs.path}/skills'));
    _personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
    _agentConfig = await AgentConfig.load(prefs);
    _activePersonaSlug = _agentConfig.defaultPersonaSlug;
    var settings = await EngineSettings.load(prefs);
    final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';
    settings = settings.copyWith(cloudApiKey: apiKey);
    final engine = buildEngine(settings);
    _structureRules = settings.structureMdOverridePath.isEmpty
        ? await DefaultAssetBundle.of(context).loadString('assets/structure.md')
        : await File(settings.structureMdOverridePath).readAsString();
    if (!mounted) return;
    if (engine == null) {
      setState(() {
        _chatMessages.add(const _ChatMessage(
          'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
          fromUser: false,
        ));
      });
      return;
    }
    _engine = engine;
    await _generate(isFreshOpen: true);
  }

  Future<void> _generate({bool isFreshOpen = false}) async {
    if (_engine == null) return;
    final isFirstOnDeviceLoad = _engine is OnDeviceLlamaEngine && !_onDeviceModelLoaded;
    setState(() => _chatBusy = true);
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
        sourceContent: _activeFileContent ?? '',
        refinementRequests: _refinements,
        guardrails: _agentConfig.guardrails,
        personaContent: personaContent,
        skillContent: skillContent,
      );
      final result = await _engine!.generate(prompt);
      if (isFirstOnDeviceLoad) _onDeviceModelLoaded = true;
      setState(() {
        _latestStructuredContent = result;
        _chatMessages.add(_ChatMessage(result, fromUser: false));
      });
    } catch (e) {
      setState(() => _chatMessages.add(_ChatMessage('Generation failed: $e', fromUser: false)));
    } finally {
      _loadTimer?.cancel();
      _loadTimer = null;
      setState(() => _chatBusy = false);
    }
  }

  Future<void> _handleSlashCommand(SlashCommand command, String rawText) async {
    setState(() => _chatMessages.add(_ChatMessage(rawText, fromUser: true)));
    if (command is SkillCommand) {
      final content = await _skillsLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _chatMessages.add(_ChatMessage('No skill named "${command.slug}".', fromUser: false)));
        return;
      }
      _pendingSkillSlug = command.slug;
      setState(() => _chatMessages
          .add(_ChatMessage('Applying skill "${command.slug}" to the next generation.', fromUser: false)));
      if (_engine != null) await _generate();
      return;
    }
    if (command is PersonaCommand) {
      final content = await _personasLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _chatMessages.add(_ChatMessage('No persona named "${command.slug}".', fromUser: false)));
        return;
      }
      setState(() {
        _activePersonaSlug = command.slug;
        _chatMessages.add(_ChatMessage('Persona switched to "${command.slug}" for this session.', fromUser: false));
      });
    }
  }

  void _sendChat() {
    final text = _chatInputController.text.trim();
    if (text.isEmpty) return;
    _chatInputController.clear();

    final command = parseSlashCommand(text);
    if (command != null) {
      _handleSlashCommand(command, text);
      return;
    }

    final path = _activeFilePath ?? '';
    final looksLikePathInstruction =
        RegExp(r'\b(save|put|store|write)\b', caseSensitive: false).hasMatch(text);
    final resolved =
        looksLikePathInstruction ? resolveSavePath(instruction: text, sourceRelativePath: path) : null;
    setState(() {
      _chatMessages.add(_ChatMessage(text, fromUser: true));
      if (resolved != null) {
        _resolvedSavePath = resolved;
        _chatMessages.add(_ChatMessage('Save path set to: $resolved', fromUser: false));
      } else {
        _refinements.add(text);
      }
    });

    if (resolved == null) {
      if (_engine == null) {
        setState(() => _chatMessages.add(const _ChatMessage(
              'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
              fromUser: false,
            )));
      } else {
        _generate();
      }
    }
  }

  List<Widget> _folderTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      if (!child.isDirectory) continue;
      tiles.add(InkWell(
        onTap: () => _pickSaveFolder(child),
        child: Padding(
          padding: EdgeInsets.fromLTRB(18 + depth * 16.0, 12, 18, 12),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 16, color: AppColors.fg),
              const SizedBox(width: 10),
              Text(child.name, style: appMono(size: 13)),
            ],
          ),
        ),
      ));
      tiles.addAll(_folderTiles(child, depth + 1));
    }
    return tiles;
  }

  void _pickSaveFolder(FileTreeNode node) {
    final resolved = resolveSavePath(
      instruction: '${node.relativePath}/',
      sourceRelativePath: _activeFilePath ?? '',
    );
    Navigator.of(context).pop();
    if (resolved == null) return;
    setState(() {
      _resolvedSavePath = resolved;
      _chatMessages.add(_ChatMessage('Save path set to: $resolved', fromUser: false));
    });
  }

  Future<void> _browseSaveFolder() async {
    final dir = _activeRepoDir;
    if (dir == null) return;
    final root = await buildFileTree(dir);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: AppColors.fg, width: 3),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Choose a folder', style: appHeading(size: 15, weight: FontWeight.w700)),
              ),
            ),
            Flexible(child: ListView(shrinkWrap: true, children: _folderTiles(root, 0))),
          ],
        ),
      ),
    );
  }

  Future<void> _pushChat() async {
    final content = _latestStructuredContent;
    final savePath = _resolvedSavePath;
    if (content == null || savePath == null) {
      _showToast('Generate a result and set a save path (via chat) before pushing.');
      return;
    }
    final dir = _activeRepoDir;
    if (dir == null) return;
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) {
      if (mounted) _showToast('GitHub Personal Access Token missing. Add one in Config.');
      return;
    }
    setState(() => _chatBusy = true);
    try {
      final service = RepoGitService(reposRoot: dir);
      await service.commitAndPush(
        repoDir: dir,
        relativeFilePath: savePath,
        content: content,
        commitMessage: 'Add structured content at $savePath',
        token: token,
      );
      if (mounted) _showToast('Pushed successfully');
    } catch (e) {
      if (mounted) _showToast('Push failed: $e');
    } finally {
      if (mounted) setState(() => _chatBusy = false);
    }
  }
```

- [ ] **Step 2: Replace `_chatBody()`'s placeholder with the real UI**

Replace:

```dart
  Widget _chatBody() {
    // Filled in by Task 6.
    return const SizedBox.shrink();
  }
```

with:

```dart
  Widget _chatBody() {
    final activePersona = _activePersonaSlug;
    return Stack(
      children: [
        Column(
          children: [
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  appIconCircleButton(icon: Icons.arrow_back, onPressed: _goBackToFiles),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _activeFilePath ?? '',
                      style: appMono(size: 13.5, weight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.fg, thickness: 2, height: 2),
            if (activePersona != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.fg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Persona: $activePersona',
                      style: appMono(size: 10, color: AppColors.bg).copyWith(letterSpacing: 0.5),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _chatMessages.length + (_chatBusy ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _chatMessages.length) {
                    if (_loadTimer != null) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          'Loading model & generating… ${_loadElapsedSeconds}s',
                          style: appMono(size: 12, color: AppColors.muted),
                        ),
                      );
                    }
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: LinearProgressIndicator(color: AppColors.fg, backgroundColor: AppColors.divider),
                    );
                  }
                  final m = _chatMessages[index];
                  return appChatBubble(text: m.text, fromUser: m.fromUser, mono: !m.fromUser);
                },
              ),
            ),
            if (_resolvedSavePath != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: AppColors.surfaceMuted,
                child: Row(
                  children: [
                    Text('Will push to ', style: appBody(size: 11, color: AppColors.muted)),
                    Text(_resolvedSavePath!, style: appMono(size: 11.5, weight: FontWeight.w600)),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  appIconCircleButton(icon: Icons.folder_outlined, onPressed: _browseSaveFolder),
                  const SizedBox(width: 8),
                  Expanded(
                    child: appBorderedField(
                      controller: _chatInputController,
                      hint: 'Refine, or say "save it in docs/posts/"',
                    ),
                  ),
                  const SizedBox(width: 8),
                  appIconCircleButton(icon: Icons.arrow_forward, onPressed: _sendChat, filled: true),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: appPrimaryButton(
                label: _chatBusy ? 'Pushing…' : 'Push to repo',
                onPressed: _chatBusy ? null : _pushChat,
              ),
            ),
          ],
        ),
        if (_toast != null)
          Positioned(
            bottom: 90,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: AppColors.fg, borderRadius: BorderRadius.circular(999)),
              child: Text(_toast!, textAlign: TextAlign.center, style: appBody(size: 12.5, color: AppColors.bg)),
            ),
          ),
      ],
    );
  }
```

- [ ] **Step 3: Delete the superseded chat screen**

```bash
git rm my_learning_projects/git_agent_app/lib/ui/chat_screen.dart
```

- [ ] **Step 4: Verify**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze lib/ui/github_tab_screen.dart lib/ui/root_screen.dart lib/main.dart`
Expected: only the expected missing-`config_screen.dart` errors (Task 7 resolves those) and no other issues.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/github_tab_screen.dart
git commit -m "feat: fold chat screen into GithubTabScreen's chat sub-screen"
```

---

### Task 7: Config tab (restyled Settings + inert LangChain/LangGraph toggles)

**Files:**
- Create: `lib/ui/config_screen.dart` (resolves the forward reference from Task 3)
- Delete: `lib/ui/settings_screen.dart`

**Interfaces:**
- Consumes: everything `lib/ui/settings_screen.dart` currently consumes, plus `AppColors`, `appHeading`, `appBody`, `appMono`, `appBorderedField`, `appPrimaryButton`, `appSecondaryButton` (Task 1).
- Produces: `class ConfigScreen extends StatefulWidget { final SecretStore secretStore; const ConfigScreen({super.key, required this.secretStore}); }` — matches `RootScreen`'s existing `ConfigScreen(secretStore: widget.secretStore)` call site from Task 3, so no changes needed there.

This is a direct, restyled port of `SettingsScreen`'s existing logic (PAT, engine choice, structure.md import/export, Skills/Personas sections, default persona dropdown, guardrails), with two new inert toggle switches added per the design spec's approved exception.

- [ ] **Step 1: Write the Config screen**

```dart
// lib/ui/config_screen.dart
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../instructions/instruction_library.dart';
import '../secrets/secret_store.dart';
import '../settings/agent_config.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';

class ConfigScreen extends StatefulWidget {
  final SecretStore secretStore;
  const ConfigScreen({super.key, required this.secretStore});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  EngineSettings _settings = const EngineSettings();
  final _patController = TextEditingController();
  final _endpointController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  final _headersController = TextEditingController();
  String? _structureMdOverridePath;
  bool _loading = true;
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  List<InstructionEntry> _skills = [];
  List<InstructionEntry> _personas = [];
  AgentConfig _agentConfig = const AgentConfig();
  final _guardrailsController = TextEditingController();
  bool _langchainEnabled = false;
  bool _langgraphEnabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = await EngineSettings.load(prefs);
      final agentConfig = await AgentConfig.load(prefs);
      final pat = await widget.secretStore.read(secretKeyGithubPat) ?? '';
      final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';

      final docs = await getApplicationDocumentsDirectory();
      final skillsLibrary = InstructionLibrary(root: Directory('${docs.path}/skills'));
      final personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
      final skills = await skillsLibrary.list();
      final personas = await personasLibrary.list();

      if (!mounted) return;
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
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load settings: $e')));
      }
    }
  }

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

  Future<void> _showEntryEditor({
    required InstructionLibrary library,
    required void Function(List<InstructionEntry>) onUpdated,
    InstructionEntry? existing,
  }) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final descriptionController = TextEditingController(text: existing?.description ?? '');
    final contentController = TextEditingController(text: existing?.content ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.fg, width: 3),
        ),
        title: Text(existing == null ? 'Add' : 'Edit', style: appHeading(size: 16, weight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              appBorderedField(controller: nameController, hint: 'Name'),
              const SizedBox(height: 10),
              appBorderedField(controller: descriptionController, hint: 'Description'),
              const SizedBox(height: 10),
              appBorderedField(controller: contentController, hint: 'Content (Markdown)', maxLines: 5),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: appBody(size: 13, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Save', style: appBody(size: 13, weight: FontWeight.w600)),
          ),
        ],
      ),
    );

    try {
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
    } finally {
      nameController.dispose();
      descriptionController.dispose();
      contentController.dispose();
    }
  }

  Widget _instructionSection({
    required String title,
    required InstructionLibrary? library,
    required List<InstructionEntry> entries,
    required void Function(List<InstructionEntry>) onUpdated,
    void Function(String slug)? onDeleted,
  }) {
    if (library == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: appHeading(size: 14, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final entry in entries)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.fg, width: 2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.name, style: appBody(size: 13.5, weight: FontWeight.w600)),
                      Text(entry.description, style: appBody(size: 11.5, color: AppColors.muted)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 16, color: AppColors.fg),
                  onPressed: () => _showEntryEditor(library: library, onUpdated: onUpdated, existing: entry),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 16, color: AppColors.fg),
                  onPressed: () async {
                    await library.delete(entry.slug);
                    onDeleted?.call(entry.slug);
                    onUpdated(await library.list());
                  },
                ),
              ],
            ),
          ),
        appSecondaryButton(
          label: '+ Add ${title.toLowerCase().substring(0, title.length - 1)}',
          onPressed: () => _showEntryEditor(library: library, onUpdated: onUpdated),
        ),
      ],
    );
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
      final prefs = await SharedPreferences.getInstance();
      final updated = _settings.copyWith(structureMdOverridePath: path);
      await updated.save(prefs);
      setState(() {
        _settings = updated;
        _structureMdOverridePath = path;
      });
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
    await Share.shareXFiles([XFile(exportFile.path)]);
  }

  Widget _toggleRow({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.fg, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: appBody(size: 13.5, weight: FontWeight.w600)),
                Text(description, style: appBody(size: 11.5, color: AppColors.muted)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.bg,
            activeTrackColor: AppColors.fg,
            inactiveThumbColor: AppColors.fg,
            inactiveTrackColor: AppColors.bg,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.fg)));
    }

    return Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 60,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text('Agent configuration', style: appHeading(size: 17, weight: FontWeight.w700)),
              ],
            ),
          ),
          const Divider(color: AppColors.fg, thickness: 2, height: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              children: [
                Text('GitHub Personal Access Token', style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 0.6)),
                const SizedBox(height: 8),
                appBorderedField(controller: _patController, hint: 'ghp_xxxxxxxxxxxx', obscure: true),
                const SizedBox(height: 22),

                Text('LLM Engine', style: appHeading(size: 14, weight: FontWeight.w700)),
                RadioListTile<EngineChoice>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Cloud API', style: appBody(size: 14)),
                  value: EngineChoice.cloud,
                  groupValue: _settings.choice,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
                ),
                if (_settings.choice == EngineChoice.cloud) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 8),
                    child: Column(
                      children: [
                        appBorderedField(controller: _endpointController, hint: 'Endpoint URL'),
                        const SizedBox(height: 8),
                        appBorderedField(controller: _apiKeyController, hint: 'API key', obscure: true),
                        const SizedBox(height: 8),
                        appBorderedField(controller: _modelController, hint: 'Model name (optional)'),
                        const SizedBox(height: 8),
                        appBorderedField(controller: _headersController, hint: 'Extra headers (Name: value per line)', maxLines: 2),
                      ],
                    ),
                  ),
                ],
                RadioListTile<EngineChoice>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('On-device (.gguf)', style: appBody(size: 14)),
                  value: EngineChoice.onDevice,
                  groupValue: _settings.choice,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
                ),
                if (_settings.choice == EngineChoice.onDevice)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _settings.onDeviceModelPath.isEmpty ? 'No model selected' : _settings.onDeviceModelPath,
                            style: appMono(size: 11.5, color: AppColors.muted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        appSecondaryButton(label: 'Choose file', onPressed: _pickOnDeviceModel),
                      ],
                    ),
                  ),
                const SizedBox(height: 22),

                Text('Agent framework', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 10),
                _toggleRow(
                  title: 'LangChain',
                  description: 'Chain prompts and tools for structuring',
                  value: _langchainEnabled,
                  onChanged: (v) => setState(() => _langchainEnabled = v),
                ),
                _toggleRow(
                  title: 'LangGraph',
                  description: 'Multi-step agent orchestration',
                  value: _langgraphEnabled,
                  onChanged: (v) => setState(() => _langgraphEnabled = v),
                ),
                const SizedBox(height: 22),

                Text('Structuring rules (structure.md)', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(_structureMdOverridePath ?? 'Using bundled default', style: appMono(size: 12, color: AppColors.muted)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: appSecondaryButton(label: 'Import', onPressed: _importStructureMd)),
                    const SizedBox(width: 8),
                    Expanded(child: appSecondaryButton(label: 'Export', onPressed: _exportStructureMd)),
                  ],
                ),
                const SizedBox(height: 22),

                _instructionSection(
                  title: 'Skills',
                  library: _skillsLibrary,
                  entries: _skills,
                  onUpdated: (updated) => setState(() => _skills = updated),
                ),
                const SizedBox(height: 22),

                _instructionSection(
                  title: 'Personas',
                  library: _personasLibrary,
                  entries: _personas,
                  onUpdated: (updated) => setState(() => _personas = updated),
                  onDeleted: (slug) async {
                    if (_agentConfig.defaultPersonaSlug == slug) {
                      setState(() => _agentConfig = _agentConfig.copyWith(clearPersona: true));
                      final prefs = await SharedPreferences.getInstance();
                      await _agentConfig.save(prefs);
                    }
                  },
                ),
                if (_personasLibrary != null) ...[
                  const SizedBox(height: 8),
                  Text('Default persona', style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 0.6)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.fg, width: 2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: _agentConfig.defaultPersonaSlug,
                        isExpanded: true,
                        dropdownColor: AppColors.bg,
                        style: appBody(size: 13),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('None')),
                          for (final p in _personas) DropdownMenuItem<String?>(value: p.slug, child: Text(p.name)),
                        ],
                        onChanged: (slug) => setState(() {
                          _agentConfig = _agentConfig.copyWith(defaultPersonaSlug: slug, clearPersona: slug == null);
                        }),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 22),

                Text('Guardrails', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                appBorderedField(
                  controller: _guardrailsController,
                  hint: 'One rule per line, always applied',
                  maxLines: 4,
                ),
                const SizedBox(height: 22),

                appPrimaryButton(label: 'Save', onPressed: _save),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _guardrailsController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 2: Delete the superseded settings screen**

```bash
git rm my_learning_projects/git_agent_app/lib/ui/settings_screen.dart
```

- [ ] **Step 3: Verify the whole project**

Run: `/home/asterisk/develop/flutter/bin/flutter analyze`
Expected: no errors (the missing-`config_screen.dart` errors from Tasks 3, 5, 6 are now resolved). Only the pre-existing 4 `RadioListTile` deprecation infos are acceptable.

- [ ] **Step 4: Run the full test suite**

Run: `/home/asterisk/develop/flutter/bin/flutter test`
Expected: all 47 existing tests still pass (this redesign touches only `lib/ui/*.dart` and `lib/main.dart` — no logic file under test changed).

- [ ] **Step 5: Manual on-device smoke test**

Build and install per the existing device workflow (`bash android/gradlew assembleDebug` from the `android/` directory, `adb install -r build/app/outputs/apk/debug/app-debug.apk`), then confirm:
- Fresh install (or after clearing app data) shows the onboarding wizard, not the old Home screen.
- Finishing or skipping onboarding lands on the 3-tab bottom nav (Chat / GitHub / Config).
- GitHub tab: repos list → tap a repo → files list → tap a file → chat, and the back arrows return to files then repos without any of them being a separate pushed route (rotate/background the app mid-flow to confirm there's no extra back-stack entry).
- Config tab shows all prior Settings fields plus the two inert LangChain/LangGraph toggles.
- Chat tab (general) shows the stub assistant message and echoes the canned reply on send.

- [ ] **Step 6: Commit**

```bash
git add lib/ui/config_screen.dart
git commit -m "feat: add restyled Config tab with inert LangChain/LangGraph toggles"
```

## Post-plan: docs sync

After all 7 tasks are implemented and reviewed, update `docs/implementation.md`'s Change log with a summary entry for this redesign (screens replaced, screens deleted, new dependency), and `docs/status_open_points.md` to note the frontend now matches the approved mockup design. The `fronten/Git Agent App Design/` folder can stay as a design reference — it's a static prototype, not shipped code, so it doesn't need to be removed.
