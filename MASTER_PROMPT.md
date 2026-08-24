# git_agent_app — Master Prompt

Give this file to an agent (or a human) that needs full context to build,
rebuild, or extend this app without re-deriving everything from scratch.

## What this app is

A small Android app: clone a GitHub repo, restructure a file's content with an
LLM following a bundled rule set, refine the result in a chat, and push it
back to the repo. v1 is a single focused pipeline — not a general git client,
not an agent framework.

**Flow:** connect GitHub (PAT) → browse & clone a repo → pick a file → LLM
restructures it against `structure.md` → refine in chat → push back
(commit + push over HTTPS).

## Stack

- Flutter 3.47.0 / Dart ^3.13.0
- `git2dart` + `git2dart_binaries` — FFI bindings to real libgit2 (clone/commit/push).
  Two other git libraries were tried first and rejected — they didn't actually
  work. See `docs/decision.md`.
- `dio` — GitHub REST API + cloud LLM HTTP calls
- `llama_cpp_dart` 0.0.9 — on-device `.gguf` inference (see build gotcha below)
- `flutter_secure_storage` — encrypted storage for GitHub PAT + cloud API key
- `shared_preferences`, `file_picker`, `share_plus`, `path_provider`

## How to build it

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"   # wherever the Flutter SDK lives
flutter pub get
flutter run                       # or: flutter build apk --debug
```

### Required one-time setup for on-device LLM support

`llama_cpp_dart` vendors `llama.cpp` as a git submodule that pub.dev's archive
doesn't include, and the pub-cache copy needs two bug patches or on-device
model loading silently "hangs" for 300 seconds (it doesn't actually hang — see
`docs/on_device_load_hang_rootcause.md`). Run once per machine, and again after
any `dart pub cache repair`:

```bash
git clone https://github.com/ggml-org/llama.cpp.git \
  ~/.pub-cache/hosted/pub.dev/llama_cpp_dart-0.0.9/src/llama.cpp   # full clone, not --depth 1
bash scripts/setup_llama_cpp_dart.sh
```

Then do a clean native rebuild:

```bash
rm -rf ~/.pub-cache/hosted/pub.dev/llama_cpp_dart-0.0.9/android/.cxx \
       build/llama_cpp_dart build/app/.cxx
bash android/gradlew assembleDebug
```

### Other environment gotchas (not app bugs)

- **NTFS/exFAT project mount**: `chmod +x` is a no-op there, so Flutter can't
  exec `android/gradlew` directly. Build with `bash android/gradlew
  assembleDebug` instead of `flutter build apk` in that case.
- **`compileSdk` mismatch on `llama_cpp_dart`**: already fixed in
  `android/build.gradle.kts` (forces `compileSdk 36` on every Android library
  subproject) — don't remove that block.
- This repo may live nested inside a larger monorepo with its own outer
  `.git`. Check `git rev-parse --show-toplevel` before committing — it's easy
  to commit into the wrong repo.

## Configuration (in-app)

Settings screen (gear icon):
- **GitHub PAT** — generate at github.com/settings/tokens with `repo` scope.
- **LLM engine** — Cloud API (endpoint, key, model, optional headers) or
  On-device (pick a local `.gguf` file).
- **structure.md** — the rule set the LLM restructures files against; import a
  replacement or export the active one.

## Status

v1 is fully implemented, test suite passing. On-device model *loading* is
verified working (~2.2s). Not yet confirmed: a live clone/push against a real
GitHub remote from the installed app, and on-device *inference* after load.
See `docs/status_open_points.md` for the current blocker and full deferred
list (OAuth login, generic git UI, LangChain/LangGraph integration, etc. — all
explicitly out of scope for v1).

## Where to look for more

- `docs/discussion.md` — how the idea was scoped down to v1
- `docs/decision.md` — every architecture decision and why
- `docs/implementation.md` — what was built, task by task, plus bugs caught
- `docs/status_open_points.md` — current status, deferred features, open risks
- `docs/on_device_load_hang_rootcause.md` — the on-device load investigation:
  what looked like a 300s hang was three bugs hiding one real error
- `docs/future_scope.md` — where this app could grow, and its honest tradeoffs
- `docs/superpowers/specs/` — the approved design spec
- `docs/superpowers/plans/` — the implementation plan the code was built from

## Ground rules for future work here

- This is v1 of a *focused pipeline*, not a platform. Don't add abstractions,
  config switches, or generic git UI beyond what a task actually needs.
- Don't casually bump the pinned `llama.cpp` commit — the FFI bindings in
  `llama_cpp_dart` are generated code with no compile-time check against the
  native structs. A reordered field is a silent segfault, not a build error.
  Re-diff `llama_model_params`/`llama_context_params` against
  `lib/src/llama_cpp.dart` first (method documented in
  `docs/on_device_load_hang_rootcause.md`).
- If something on-device looks like a hang, restore log visibility (route
  `llama_log_set` through `print`, temporarily — but never leave a
  `Pointer.fromFunction` log callback installed permanently, it can crash on a
  native worker thread; use `NativeCallable.listener` for anything durable)
  before spending time on hardware/memory/threading hypotheses. In this app's
  history, one log callback ended an investigation that eight black-box
  experiments couldn't.
