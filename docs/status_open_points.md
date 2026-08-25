# Status & Open Points — git_agent_app

## Status

- 2026-08-23: Design brainstormed and approved. Spec written to
  `docs/superpowers/specs/2026-08-23-v1-clone-structure-push-design.md`.
- Implementation plan: written and executed — all 15 plan tasks implemented and reviewed
  (a final whole-branch review pass fixed secret storage, re-clone, path-traversal, and
  other findings).
- Code: complete for v1. Git operations use git2dart (real libgit2 FFI bindings), not
  dart_git as originally planned.
- 2026-08-23: Debug APK built and installed on a physical Android device (V2231,
  Android 15). Home and Settings screens confirmed rendering correctly with no crash;
  navigation between them works both ways. This was a UI-only smoke test — no PAT or
  LLM was configured, so clone/structure/push were not exercised yet.
- 2026-08-23: Device testing surfaced a real bug (repo list didn't detect
  already-cloned repos) — fixed same day, see `implementation.md`.
- 2026-08-23: Skills/personas/guardrails: **implemented** — spec at
  `docs/superpowers/specs/2026-08-23-skills-personas-guardrails-design.md`, plan at
  `docs/superpowers/plans/2026-08-23-skills-personas-guardrails.md` (8 tasks, all
  reviewed clean, final-review fix pass applied). Skills/Personas library UI, default
  persona, guardrails, slash commands, and the on-device load elapsed-time indicator
  are all live in the app.
- 2026-08-23: Frontend redesign: **implemented** — bottom-tab nav (Chat/GitHub/Config),
  onboarding wizard, black/white visual system, GitHub tab rebuilt as a flat state
  machine. Spec at `docs/superpowers/specs/2026-08-23-frontend-redesign-design.md`,
  plan at `docs/superpowers/plans/2026-08-23-frontend-redesign.md` (7 tasks, final-review
  fix pass applied, ready to merge). See `implementation.md`'s Change log for details.
- 2026-08-24: Post-launch fixes: **implemented** — a real crash in the on-device
  "Choose file" button (infinite-width `SizedBox` inside an unbounded `Row`) and
  missing `SafeArea` on three tab screens (headers rendered under the status bar).
  Both fixed and verified on-device; see `implementation.md`'s Change log.
- 2026-08-24: Config's Models section (load/offload/uninstall on-device model,
  active-status display): **implemented** — `OnDeviceEngineRegistry` shares one
  engine instance app-wide so Config's controls and chat generation agree on
  loaded state. See `implementation.md`'s Change log.
- 2026-08-24: Repo-aware General Chat: **implemented** — General Chat now has
  a real LLM engine, tap-based repo/file selection (cloning if needed),
  tree-only repo context by default, on-demand file reads via "Ask about
  this file," and a "Structure this file" handoff into the GitHub tab's
  existing structuring chat. Spec at
  `docs/superpowers/specs/2026-08-24-repo-aware-chat-design.md`, plan at
  `docs/superpowers/plans/2026-08-24-repo-aware-chat.md` (6 tasks, final-review
  fix pass applied for a stale-cached-engine bug and a cross-screen
  destructive-reclone race, both confirmed fixed). See `implementation.md`'s
  Change log for details.

## Planned work — raised 2026-08-25 (design approved, not yet implemented)

Eight items raised together; specced as five independent subsystems plus one
blocking bug in
`superpowers/specs/2026-08-25-multi-llm-observability-agent-controls-design.md`.

| Phase | Item | Notes |
|---|---|---|
| **0** | **BUG: on-device LLM produces no output at all** — silent past 10 min, no error | Highest priority. `generate()` buffers the whole response and returns only at completion, so a working slow generation and a dead hang look identical. |
| **1** | Per-step / per-token generation visibility | Same code change as Phase 0: `LlmEngine` gains an event stream; chat renders tokens live plus a real status line. |
| **2** | Multi-LLM library — adding an LLM currently **replaces** the existing one | New `lib/settings/llm_library.dart`; one list holding both on-device and cloud entries. Switching auto-unloads the previous model. Deletion made explicit about whether the file is removed from disk. |
| **3a** | Live CPU/RAM in the chat top bar | This app's own usage from `/proc/self`, no new dependency. Never a fabricated number. |
| **3b–c** | Scroll to newest content after repo selection and icon interactions | Applied to all insertions, not special-cased. |
| **3d** | Collapsible folders in the file tree | Feasibility gate: needs real widgets over `lib/files/file_tree.dart`. If the tree is flat text today, the display is rebuilt (text path for LLM context stays). |
| **4** | LangChain/LangGraph toggles made real: descriptions, haptics, loop-depth control | Extends `AgentConfig`; adds a `◀ 3 ▶` stepper to `app_theme.dart` (no stepper exists yet). Must state plainly that no framework backend exists yet rather than implying an effect. |
| **5** | Multi-step task decomposition with per-step output + consolidated result | Cloud only (refused on-device, with an in-UI explanation). Hard 5-step cap, hard token budget, confirm-before-run, running compact summary instead of resending step outputs, live cost counter, kill switch. |

Confirmed with the user during design: one unified LLM list (on-device +
cloud); switching unloads the old model; metrics are app-scoped; Phase 5 is
cloud-only and conservative on cost.

Open items to confirm before implementation: whether the chat screen shares
Config's `OnDeviceEngineRegistry` instance; whether the folder tree is widgets
or flat text; whether a prior agreed value exists for Phase 4's loop levels;
`/proc/self` readability on the physical device.

## Open points needing Jaya's input (raised 2026-08-25, autonomous session)

### 1. Re-verify the stop-sequence fix on-device (ACTION, not a decision)

**What:** The `-O3` performance fix was verified on the phone (0.43 → ~2.5
tok/s, reply completing in 14s). The stop-sequence fix, the `Assistant:` prompt
cue, and `nPredict` 32→256 / `nCtx` 512→2048 were committed *after* the device
disconnected, so they are unit-tested (6 tests) but **not yet confirmed on
hardware**.

**Why it matters:** the whole point of this work is that runtime behaviour is
the evidence, not passing tests.

**To do:** plug the phone in, `bash android/gradlew assembleDebug`, install,
load the model, ask "hello", and confirm the reply stops after one turn instead
of inventing a `User:` line.

### 2. On-device inference speed is still modest — accept or tune?

**What:** after the `-O3` fix, gemma-3-1b-Q4 runs at ~2.5 tok/s on the vivo
V2231. A ~30-word answer takes roughly 15–20 seconds.

**Understanding:** `-O0` was the dominant cause and is fixed. The remaining
rate is plausible for a 1B model on a mid-range CPU with no GPU backend
compiled in, but it has not been tuned.

**Options considered:**
- *Accept as-is* — honest streaming UI already makes the wait legible.
  Zero risk, no further work.
- *Tune thread count* — `nThreads` is 8; the device is 6×2.0GHz + 2×2.8GHz.
  Trying 4 and 6 is cheap and might give 10–30%. Needs the device to measure.
- *Compile ARM dotprod/i8mm kernels* — PocketPal ships separate `.so` variants
  per CPU feature level (`librnllama_v8_2_dotprod_i8mm.so`). Potentially a
  large gain on quantised matmul, but means per-variant native builds and real
  build-system work.
- *Add a GPU backend (Vulkan)* — biggest potential gain, biggest risk; a GPU
  backend was what caused the original SIGSEGV, and `nGpuLayers = 0` is
  currently load-bearing.

**Recommendation:** accept for now, and try the thread-count tuning next time
the device is attached, since it is nearly free. Treat the dotprod/Vulkan work
as its own project, not a tweak.

### 3. Which cloud model should Phase 5 multi-step default to?

**What:** the multi-step orchestrator is cloud-only by decision. Cost per run
depends heavily on the model, and no default was chosen.

**Why it matters:** it determines the default token budget and the realistic
cost of a 5-step run.

**Recommendation:** leave the model as whatever the active cloud entry uses,
and make the token budget the safety mechanism rather than hard-coding a model.
No action needed unless you disagree.

## Open points (deferred, not blocking v1)

- Full OAuth device/web flow instead of PAT.
- LangChain/LangGraph or other agent framework integration with an on/off switch.
- Generic git actions UI (branch, diff, merge, history) beyond commit+push of one file.
- Multi-repo / multi-file workflows in a single session.
- Persisting chat history across app restarts.
- Automated UI test suite (v1 relies on manual testing against a throwaway repo, plus
  one targeted unit test for the chat-instruction-to-repo-path resolver).

## Risks to watch

- **BLOCKER:** the real clone/push flow (git2dart over HTTPS+PAT) against an actual
  GitHub remote has NEVER been executed end-to-end. All git behavior is currently
  verified only by unit tests / code review, not a live run. This must happen before
  any real use. Running it means: a human with a real GitHub PAT and a throwaway repo
  does the manual smoke test described in the plan's Task 8 (clone) and Task 15
  (commit + push), confirming the repo actually clones and a real commit lands and
  pushes to GitHub.
- On-device gguf *loading* is now verified on the vivo V2231 (qwen2.5-0.5B-q5_K_M loads
  in ~2.2s). Inference performance/memory after load is still unverified; the cloud path
  should still be the one exercised first end-to-end.
- **On-device load requires a one-time per-machine setup step**:
  `bash scripts/setup_llama_cpp_dart.sh`, then a clean native rebuild. It pins
  `llama.cpp` to `ab1401982` and patches two `llama_cpp_dart` bugs. Skipping it, or
  running `dart pub cache repair`, brings the "300-second hang" straight back. Full
  root-cause writeup in `on_device_load_hang_rootcause.md`.
- **Never bump the pinned `llama.cpp` commit casually.** The 0.0.9 FFI bindings are
  generated code with no compile-time validation; a reordered struct field in
  `llama_model_params`/`llama_context_params` yields a silent SIGSEGV, not a build error.
- **Known limitation, not fixable without a library change:** true percentage-based
  model-load progress is unavailable — `llama_cpp_dart 0.0.9`'s `ModelParams`
  hardcodes libgit2's `progress_callback` to `nullptr`. Working around this with an
  honest elapsed-time counter instead (see the skills/personas/guardrails spec, Part
  1). Revisit only if a future `llama_cpp_dart` release exposes real progress.
