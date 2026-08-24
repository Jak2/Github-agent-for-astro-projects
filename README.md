# git_agent_app

A small Android app: clone a GitHub repo, restructure a file's content with an LLM
following a bundled rule set, refine the result in a chat, and push it back to the repo.

This is v1 — a single focused pipeline, not a general git client or agent framework.
See `docs/` for the full design history and decisions.

## What it does

1. **Connect GitHub** — paste a Personal Access Token in Settings.
2. **Browse & clone** — pick one of your repos from a list; it's cloned to the app's
   local storage.
3. **Pick a file** — browse the cloned repo's file tree and tap a file.
4. **Structure it** — the file's content plus a bundled `structure.md` rule set are
   sent to an LLM (cloud API or an on-device `.gguf` model), which returns restructured
   Markdown.
5. **Refine in chat** — ask for changes ("make it shorter", "add a summary section")
   and the LLM regenerates; keep going until it's right.
6. **Push it back** — tell the app where to save it (type a path in chat, or browse
   the repo tree to pick a folder), then tap Push. The app commits and pushes to the
   repo over HTTPS.

## Stack

- Flutter 3.47.0 / Dart 3.13.0
- `git2dart` + `git2dart_binaries` — FFI bindings to real libgit2 for clone/commit/push
- `dio` — GitHub REST API + cloud LLM HTTP calls
- `llama_cpp_dart` — on-device `.gguf` inference
- `flutter_secure_storage` — encrypted storage for the GitHub PAT and cloud API key
- `shared_preferences`, `file_picker`, `share_plus`, `path_provider`

See `docs/decision.md` for why `git2dart` specifically (two other git libraries were
tried and rejected during implementation because they turned out to not actually work).

## Building & running

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"   # or wherever your Flutter SDK lives
flutter pub get
flutter run   # or: flutter build apk --debug
```

### Known environment gotchas (not app bugs)

- **If the project lives on an NTFS/exFAT mount** (`chmod +x` is a no-op there),
  Flutter's tooling can't exec `android/gradlew` directly. Build via
  `bash android/gradlew assembleDebug` instead of `flutter build apk` in that case.
- **`llama_cpp_dart` needs a one-time manual step, once per machine.** It vendors
  `llama.cpp` as a git submodule that pub.dev's package archive doesn't include, so the
  on-device build fails with a CMake `add_subdirectory` error until you clone it — and
  the package then needs pinning plus two patches, or on-device model loading appears to
  hang for 300 seconds:
  ```bash
  git clone https://github.com/ggml-org/llama.cpp.git \
    ~/.pub-cache/hosted/pub.dev/llama_cpp_dart-0.0.9/src/llama.cpp
  bash scripts/setup_llama_cpp_dart.sh   # pins llama.cpp + patches the package
  ```
  Re-run the script after `dart pub cache repair` (it's idempotent), then do a clean
  native rebuild. Why it's needed: `docs/on_device_load_hang_rootcause.md`. Note the
  clone must be a full clone, not `--depth 1`, since the script checks out a pinned
  commit.
- **`compileSdk` mismatch on `llama_cpp_dart`.** Already fixed in
  `android/build.gradle.kts` (forces `compileSdk 36` on every Android library
  subproject) — no action needed, just don't remove that block.

Full details, including every deviation found during implementation, are in
`docs/implementation.md`.

## Configuration

Open the app's Settings screen (gear icon) to set:

- **GitHub Personal Access Token** — generate one at github.com/settings/tokens with
  `repo` scope, paste it in.
- **LLM engine** — Cloud API (endpoint, API key, model name, optional extra headers)
  or On-device (pick a local `.gguf` file).
- **structure.md** — the bundled default ships in the app; import a replacement from
  local storage, or export the currently active one to share/save it.

## Status

v1 is fully implemented and passing its test suite (see `docs/status_open_points.md`
for the current blocker: a live clone/push against a real GitHub remote from the
installed app hasn't been confirmed yet). Not in scope for v1: OAuth login, a
skills/sub-agent library, LangChain/LangGraph integration, or a generic git UI beyond
commit+push of one file — see `docs/status_open_points.md` for the full deferred list.

## Docs

- `docs/discussion.md` — how the idea was scoped down to v1
- `docs/decision.md` — every architecture decision and why, including two git-library
  swaps discovered mid-implementation
- `docs/design_theory.md` — the principles behind those decisions, plus the visual
  system (colour, type, components) and native-dependency discipline
- `docs/implementation.md` — what was actually built, task by task, plus real bugs
  caught along the way
- `docs/status_open_points.md` — current status, deferred features, open risks
- `docs/superpowers/specs/` — the approved design spec
- `docs/superpowers/plans/` — the implementation plan the code was built from
# Github-agent-for-astro-projects
