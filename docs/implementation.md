# Implementation — git_agent_app

v1 ("Clone → Structure → Push") is implemented, reviewed, and installed on a physical
device for manual testing. This file tracks what was actually built, in what order, and
the real deviations from the plan discovered along the way.

Spec: `superpowers/specs/2026-08-23-v1-clone-structure-push-design.md`
Plan: `superpowers/plans/2026-08-23-v1-clone-structure-push.md`
Decisions: `decision.md`
Discussion history: `discussion.md`
Open points: `status_open_points.md`

## How it was built

Executed via the `subagent-driven-development` workflow: a fresh implementer subagent
per plan task, a task-scoped reviewer after each, and one final whole-branch review at
the end. All 15 plan tasks were implemented and passed review (several needed one fix
pass before approval — see below). 23 unit tests pass; `flutter analyze` is clean except
4 pre-existing info-level `RadioListTile` deprecation notices in `settings_screen.dart`.

## Task-by-task summary

| # | Task | Notes |
|---|------|-------|
| 1 | Project scaffold | `flutter create` + dependencies. `llama_cpp_dart` had to be pinned to `^0.0.9` (not the plan's `^0.2.2`) to resolve an `archive` package version conflict with the originally-planned git library. |
| 2 | `EngineSettings` | Persisted engine config (cloud/on-device), `SharedPreferences`-backed. |
| 3 | `LlmEngine` implementations | `CloudApiEngine` (Dio-based), `OnDeviceLlamaEngine` (llama_cpp_dart isolate API). |
| 4 | `EngineFactory` | `buildEngine()` returns `null` on incomplete config — no fake-engine fallback, enforced project-wide. |
| 5 | `SecretStore` | Encrypted storage abstraction over `flutter_secure_storage`. |
| 6 | GitHub repo listing | REST API client + JSON parsing. |
| 7 | Repo local storage paths | Pure path-resolution helpers. |
| 8 | `RepoGitService` | **Rebuilt twice.** See "Git library history" below — this was the highest-risk task in the plan. |
| 9 | File tree builder | Builds a `FileTreeNode` tree from a cloned repo directory. |
| 10 | Save-path resolver + prompt builder | Caught and fixed a real cascade-on-void syntax bug in the plan's own example code, and a doc-comment/behavior mismatch (comment said "longest token wins", code actually implements "last token wins" — fixed the comment, since "last wins" is the more sensible chat semantics). |
| 11 | Settings screen | PAT + cloud/on-device engine config + structure.md import/export. |
| 12 | Repo list screen | Lists + clones repos; fix pass added a missing error snackbar for a stale-PAT edge case. |
| 13 | File browser screen | Renders the cloned repo's file tree. |
| 14 | Chat/refine/push screen | Core screen. Fix pass added feedback-on-send when unconfigured, disposed a leaked controller, clarified an unused constructor param. |
| 15 | Wire navigation | `main.dart` entrypoint; added the `PlatformSpecific.initialize()` call git2dart requires at startup (discovered in Task 8). |

## Git library history (the big deviation)

The plan went through **two library swaps** before landing on a working git
implementation — each one found by an implementer subagent actually reading the
library's source rather than trusting its README:

1. **`dart_git`** (original spec pick) — abandoned before implementation started:
   v0.0.2, last published 5 years ago, no documented push support.
2. **`git_on_dart`** (swapped in during planning, looked active at v0.1.4) — Task 8's
   implementer read its actual source and found HTTPS clone/push are non-functional
   stubs: the library's own comments admit packfile transfer "would need pack
   protocol" / "not implemented". Clone never writes git objects; push sends a request
   body GitHub's server can't parse. This was caught before any real damage, but did
   require a full second implementation pass on Task 8.
3. **`git2dart` + `git2dart_binaries`** (current) — FFI bindings to the real libgit2 C
   library, with prebuilt native libraries bundled by the companion package. The
   controller independently verified from source that `git2dart`'s push path calls
   `libgit2.git_remote_push` via FFI — a genuine protocol-correct call, not
   hand-rolled bytes.

`git2dart` requires a one-time `await PlatformSpecific.initialize()` call before any
git2dart usage (configures Android SSL certs, loads libgit2) — wired into `main.dart`
in Task 15.

## Final whole-branch review fix pass

The final review (before this device test) found and fixed, in one commit (`a78e410`):

- **Critical:** the cloud API key was persisted in plaintext `SharedPreferences`
  instead of `SecretStore` — moved to secure storage alongside the PAT.
- Re-cloning an already-cloned repo always failed (libgit2 refuses to clone into a
  non-empty directory) — now deletes the existing directory first.
- No path-traversal guard on the chat-instruction save path — `resolveSavePath` now
  rejects absolute paths and `..` segments.
- `structure.md` import was inert (picked a file but never used it) — now persisted
  and actually consumed at generation time.
- The spec's "browse repo tree to pick a save folder" option didn't exist (only the
  chat-instruction path did) — added a folder-picker bottom sheet to the chat screen.
- Silent failure (no feedback) when the PAT is missing at push time — now shows a
  snackbar.
- Refinement text containing a slash (e.g. "add a section on CI/CD") could be
  misread as a save-path instruction — added a lead-in-verb heuristic
  (save/put/store/write) before trusting the resolver's output.

## Getting it running on a real device (environment notes specific to this workspace)

Two environment-specific problems came up installing on a physical Android device that
are **not** app bugs — recorded here so they don't get re-debugged from scratch:

1. **`gradlew` "lacked sufficient permissions to execute".** The project lives on an
   NTFS drive mounted via `fuseblk` (`/media/asterisk/windows_drive`) — `chmod +x` is a
   no-op on that filesystem, so `flutter build apk` / `flutter run` can't exec
   `gradlew` directly. Workaround: invoke the wrapper explicitly —
   `bash android/gradlew assembleDebug` — instead of letting Flutter's tooling shell
   out to it directly. (`sh` fails too — the wrapper script uses bash-only syntax.)
2. **CMake error: `add_subdirectory` failed for `llama.cpp`.** `llama_cpp_dart 0.0.9`
   vendors `src/llama.cpp` as a git submodule that pub.dev's package archive does not
   include (pub doesn't fetch git submodules). The directory is empty after
   `flutter pub get`. Fix: manually clone it once —
   ```bash
   cd ~/.pub-cache/hosted/pub.dev/llama_cpp_dart-0.0.9/src
   git clone --depth 1 https://github.com/ggml-org/llama.cpp.git llama.cpp
   ```
   This only needs to happen once per machine/pub-cache, not per build.

## Device install (2026-08-23)

Built and installed the debug APK on a physical device (V2231, Android 15/API 35,
arm64) via `adb install`. Two more environment-specific build failures came up beyond
the two above, both now fixed in the repo (not workarounds you need to repeat):

3. **`compileSdk` mismatch.** `llama_cpp_dart`'s Android module declares `compileSdk
   31`, but several transitive AndroidX dependencies (`androidx.core:core:1.13.1`,
   `androidx.activity:activity:1.8.1`, etc.) require `compileSdk >= 33`. Gradle's
   strict dependency check fails the whole build over this even though nothing in
   *this app* needs the newer APIs directly. Fixed in `android/build.gradle.kts` with
   a `subprojects { afterEvaluate { ... compileSdkVersion(36) } }` block that forces
   every Android library subproject (not just `:app`) to compile against SDK 36. This
   block must be registered *before* the existing `evaluationDependsOn(":app")` call
   in the same file — registering it after throws "Cannot run
   Project.afterEvaluate(Action) when the project is already evaluated" because
   `evaluationDependsOn` forces early evaluation.
4. Confirmed `bash android/gradlew assembleDebug` (see gotcha #1 above) is the
   reliable way to build in this NTFS-mounted workspace — `flutter build apk` /
   `flutter run` still can't exec the wrapper directly.

**Result:** `BUILD SUCCESSFUL`, APK installed and launched with no crash. Verified by
screenshot: Home screen renders correctly ("Browse your repositories" button, gear
icon), Settings screen renders correctly (PAT field, LLM engine radio group with
conditional cloud/on-device fields, structure.md import/export, Save button), and
Home ↔ Settings navigation works both directions (gear icon in, back arrow out).

This was a UI smoke test only — no GitHub PAT or LLM was configured during this pass,
so cloning, structuring, and pushing were not exercised. That remains the real
blocker below.

## Still unverified

The real clone/commit/push flow has not yet been exercised against a live GitHub
remote from the installed app (see `status_open_points.md`'s BLOCKER entry). Nor has
the full pipeline (clone → pick file → generate → refine → push) been run end to end
with a real PAT and LLM configured — only the Home/Settings shell has been visually
confirmed so far.

## Change log

Going forward, changes made outside a formal plan's task list (bug fixes from device
testing, small follow-ups) are logged here individually — file(s) touched, what
changed, why — rather than only summarized after the fact. Formal plan-driven work
still gets its own task-by-task section like the one above.

### 2026-08-23 — repo list didn't detect already-cloned repos

**Reported by:** user, after device testing v1.

**Root cause:** `lib/ui/repo_list_screen.dart`'s `_load()` fetched the repo list from
GitHub but never checked local disk state, so every row always rendered the download
icon and `_clone()` always re-cloned, even for a repo already present locally.

**Fix:**
- `_load()` now calls `repoDirectory(reposRoot, repo.fullName)` (from
  `lib/git/repo_paths.dart`, already existed) for every listed repo and builds a
  `Set<String> _alreadyClonedFullNames` of repos whose directory already exists.
- Row UI: an already-cloned repo shows a "Already cloned — tap to open" subtitle and
  a folder-open icon instead of the download icon.
- Tapping an already-cloned row calls a new `_openExisting()` which resolves the
  existing directory and navigates straight to `FileBrowserScreen` — no clone, no
  network call, no PAT read.
- Tapping a not-yet-cloned row still goes through the existing `_clone()` path
  unchanged; on successful clone, `_alreadyClonedFullNames` is updated in place so the
  row switches state without needing a full reload.

**Verified:** `flutter analyze lib/ui/repo_list_screen.dart` — no issues.

**Not yet re-verified on-device** (this fix landed after the last device install) —
next device test should re-visit the repo list after a clone to confirm the row
switches to "Already cloned" and reopens without re-downloading.

### 2026-08-23 — Frontend redesign (bottom-tab UI, onboarding, GitHub flat state machine)

**Driven by:** user-supplied design mockup (`fronten/Git Agent App Design/git_agent_app.dc.html`),
formalized in `docs/superpowers/specs/2026-08-23-frontend-redesign-design.md` and executed via
`docs/superpowers/plans/2026-08-23-frontend-redesign.md` (7 tasks, subagent-driven).

**What changed:**
- New `lib/theme/app_theme.dart` — black/white visual system (`AppColors`, `appHeading`/
  `appBody`/`appMono` via `google_fonts`' Sora/Inter/JetBrains Mono, reusable bordered-field/
  button/chat-bubble widgets) applied app-wide via `MaterialApp.theme`.
- New `lib/ui/onboarding_screen.dart` — one-time 3-step wizard (PAT → repos preview → LLM
  engine), gated by a persisted `onboarded` SharedPreferences flag read in `main.dart`.
- New `lib/ui/root_screen.dart` — 3-tab bottom nav (`Chat` / `GitHub` / `Config`) replacing the
  old single-button `HomeScreen`, which is now deleted.
- New `lib/ui/general_chat_screen.dart` — a stub assistant tab (static message + canned reply,
  no LLM call), per the approved design spec exception.
- `lib/ui/repo_list_screen.dart`, `lib/ui/file_browser_screen.dart`, and `lib/ui/chat_screen.dart`
  deleted; their logic (clone/already-cloned detection, file-tree browsing, generation, slash
  commands, persona/skill/guardrails composition, on-device load timer, save-path resolution,
  push) is folded verbatim into `lib/ui/github_tab_screen.dart` as one flat state machine
  (`_subScreen`: `repos | files | chat`) with `PopScope`-driven back navigation instead of
  `Navigator.push`.
- `lib/ui/settings_screen.dart` deleted; replaced by `lib/ui/config_screen.dart` — same fields
  restyled, plus two inert LangChain/LangGraph toggle switches (approved exception to
  decision.md #12 — no backend, no persistence).
- New dependency: `google_fonts: ^6.2.1`.
- No backend logic changed — `InstructionLibrary`, `AgentConfig`, `EngineSettings`,
  `SecretStore`, `RepoGitService`, `buildStructuringPrompt`, `parseSlashCommand` are all byte-
  for-byte unchanged; the 47 existing tests kept passing throughout.

**Final-review fix pass** (`61d0885`) addressed 5 real cross-task integration gaps a per-task
reviewer couldn't see: chat send/browse buttons weren't disabled while busy (could fire
overlapping generations); the GitHub tab's repo list had no way to retry after a PAT was added
post-launch (permanently stuck error since `IndexedStack` preserves tab state); Android hardware
back exited the whole app instead of navigating the flat state machine (fixed with `PopScope`);
`ConfigScreen` leaked 5 `TextEditingController`s; the skill/persona entry dialog's Name field
lost its edit-lock during the port. All confirmed fixed on re-review.

**Environment note for future subagent-driven work:** subagent implementers' own `git commit`
calls did not persist to this repo throughout this plan's execution — every commit was made by
the controller after independently verifying each implementer's uncommitted diff matched its
brief. If this recurs, instruct implementers not to commit at all and have the controller commit
directly, as was done here from Task 3 onward.

### 2026-08-24 — responsive-layout crash and status-bar overlap (post-launch device test)

**Reported by:** user, after installing the redesigned frontend — "the ui layout is going
out of the screen."

**Root cause (crash):** `appPrimaryButton`/`appSecondaryButton` (`lib/theme/app_theme.dart`)
both wrap their child in `SizedBox(width: double.infinity)`, which fills whatever width its
parent hands it. `config_screen.dart` and `onboarding_screen.dart` each placed the on-device
"Choose file" `appSecondaryButton` as a direct child of a `Row` with no `Expanded` — a `Row`
gives unconstrained (infinite) width to non-flex children, so the infinite-width `SizedBox`
threw a `BoxConstraints` layout assertion mid-frame and froze rendering. This only reproduced
when `EngineSettings.choice == EngineChoice.onDevice` (the "Choose file" row is conditionally
built only for that engine choice), which happened to be the saved setting on the test device —
so Config appeared to silently go blank on every launch, with no crash visible in `adb logcat`
(the frozen frame's cached pixels stayed on screen). Root-caused by attaching a live debug
session (`flutter attach`) to catch the actual `RenderFlex`/`SizedBox` exception, since a
plain `adb install` + `logcat` didn't surface it.

**Fix:** wrapped both "Choose file" button call sites in a fixed-width `SizedBox(width: 120)`
instead of leaving them unbounded in the `Row`.

**Root cause (status-bar overlap):** `ConfigScreen`, `GithubTabScreen`, and
`GeneralChatScreen`'s `Scaffold` bodies weren't wrapped in `SafeArea` — only
`OnboardingScreen` had one. Header text rendered under the status bar/notch on those three
tabs.

**Fix:** added `SafeArea(bottom: false)` to all three (`bottom: false` since
`RootScreen`'s `bottomNavigationBar` already reserves that space).

**Also:** disabled Impeller via an `AndroidManifest.xml` meta-data entry
(`io.flutter.embedding.android.EnableImpeller = false`) while investigating — ruled out as
the cause (the crash reproduced identically with Impeller off), but left disabled since this
test device's Mali GPU logged `mali_gralloc` format warnings at every launch and Skia is the
safer default there.

**Verified:** `flutter analyze` (0 errors), `flutter test` (47/47), and on-device — Config
tab renders fully with the on-device engine selected, headers clear the status bar on all
three tabs.

### 2026-08-24 — Models section in Config (load / offload / uninstall)

**Requested by:** user — "after choosing on-device, I want to see if the model is active."

**What changed:**
- `lib/engine/on_device_llama_engine.dart` — added `isLoaded` getter and public `load()`/
  `unload()` methods, so the model's lifecycle can be driven explicitly instead of only
  lazily loading inside `generate()`.
- `lib/engine/on_device_engine_registry.dart` (new) — a single app-wide
  `OnDeviceLlamaEngine` instance keyed by model path. `engine_factory.dart`'s
  `buildEngine()` now routes on-device requests through this registry instead of
  constructing a fresh instance per call site, so Config's Load/Offload controls and the
  chat screen's actual generation observe and act on the same loaded state.
- `lib/ui/config_screen.dart` — new "Models" section under the on-device engine choice:
  shows the configured model's filename, a status dot (green "Active — loaded in memory" /
  grey "Not loaded"), and Load / Offload / Uninstall buttons. Uninstall confirms first,
  then unloads, deletes the file from disk, and clears the saved path.

**Verified:** `flutter analyze` (0 errors), `flutter test` (47/47), and on-device (empty
state confirmed rendering correctly; full load/offload/uninstall flow needs a real `.gguf`
on a test device to exercise end to end — not yet done).

### 2026-08-24 — Repo-aware General Chat

**Requested by:** user — "I want the app to answer normal questions about the repos, and
select the repo from the chat itself and traverse and work on the file I want."

**What changed (6 tasks, `docs/superpowers/plans/2026-08-24-repo-aware-chat.md`):**
- `lib/files/file_tree_text.dart` (new) — `renderFileTreeAsText(FileTreeNode)`, a pure
  function rendering a file tree as indented text for the LLM's context.
- `lib/chat/pending_file_handoff.dart` (new) — `PendingFileHandoff`, a one-shot app-wide
  singleton carrying a "please open this file in the structuring chat" request from
  General Chat to the GitHub tab.
- `lib/github/repo_browser_service.dart` (new) — `loadReposWithCloneStatus`, extracted
  from `GithubTabScreen`'s previously-inline repo-listing logic so both screens share one
  implementation; `GithubTabScreen`'s clone-on-tap flow itself was left untouched.
- `lib/ui/general_chat_screen.dart` (rewrite) — General Chat is now a real, LLM-backed
  assistant: "Browse repos" and "Browse files" post tappable lists into the chat thread;
  tapping a file offers "Ask about this file" (reads it into the conversation's context,
  stays in Chat) or "Structure this file" (hands off to the GitHub tab via
  `PendingFileHandoff` + a tab-switch callback). Before a file is opened, the LLM sees
  only the repo's file/folder tree — never file contents.
- `lib/ui/root_screen.dart` / `lib/ui/github_tab_screen.dart` — small wiring: `RootScreen`
  passes a tab-switch callback into `GeneralChatScreen`; `GithubTabScreen` picks up a
  pending handoff via `didUpdateWidget` (the correct hook since `IndexedStack` keeps its
  State alive across tab switches — `initState` only fires once at app start).

**Final-review fix pass** (`3a89651`) addressed 2 real cross-task integration bugs a
per-task reviewer couldn't see: General Chat's LLM engine was cached from `initState` and
never refreshed, so configuring an LLM after the initial "not configured" message left
Chat permanently stuck until an app restart (`GithubTabScreen` didn't have this bug since
it re-resolves settings on every file open) — fixed by resolving the engine fresh on every
send. And both screens' "already cloned" status was a stale snapshot from list-load time;
cloning a repo from one screen and then tapping it in the other's stale list fell through
to the clone path, which deletes the existing directory before re-cloning — fixed by
re-checking the directory's real existence on disk at tap time in both screens, before
deciding whether to clone. Both confirmed fixed on re-review.

**Verified:** `flutter analyze` (0 errors), `flutter test` (57/57 — 47 prior + 10 new: 4
for `file_tree_text`, 3 for `pending_file_handoff`, 3 for `repo_browser_service`). Manual
on-device smoke test (browse repos → select → browse files → ask about a file → structure
a file and confirm the handoff lands in the GitHub tab) not yet run — needs a real GitHub
PAT and LLM configured on a test device.
