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

- 2026-08-25/26: **Generation observability, multi-LLM, pinning, file writing and a
  git action bar** — a large block of work, all implemented and committed. Spec:
  `docs/superpowers/specs/2026-08-25-multi-llm-observability-agent-controls-design.md`,
  plan: `docs/superpowers/plans/2026-08-25-generation-observability.md`. Test suite
  grew 63 -> 265. Highlights:
  - **The "silent LLM" was never stuck.** It generated the whole time at 0.43 tok/s
    behind an API that returned only at completion. Two real causes: debug APKs built
    llama.cpp at `-O0` (forcing `-O3` gave ~2.5 tok/s, ~6x), and nothing stopped
    generation, so the model role-played both sides of the transcript. Full writeup in
    `on_device_load_hang_rootcause.md` and `implementation.md`.
  - `LlmEngine` gained an event stream: tokens render live, with a real status line
    (`model ready -> prompt sent -> generating (N tokens)`), a stop button, and no
    reachable blank bubble.
  - `LlmLibrary` — saving an LLM no longer replaces the previous one; on-device and
    cloud entries live in one list, switching unloads the old model first.
  - Chat UX: live CPU/RAM from `/proc/self`, uniform scroll-to-newest, collapsible
    folders, and **pinning** a repo/folder/file to scope what the LLM is asked about.
  - The assistant can create files in the local clone via a fenced `create-file` block,
    behind an editable confirm card; plus deterministic **New file** / **New folder**
    actions and a repo folder picker.
  - **Git action bar in chat** (Status, Log, Branches, New file, New folder,
    Check access, Pull, Commit & push) — deliberately buttons, not prompt-driven, so
    they cost zero tokens and cannot be hallucinated.
  - Real LangChain backend (`langchain` 0.8.1 + a `SimpleChatModel` adapter over our
    engines) and an in-app graph engine (`lib/agent/graph_engine.dart`).

- 2026-08-26: **Live GitHub push verified end-to-end** — `Committed 2 path(s) as
  99d3831 and pushed to origin/main` from the installed app against `Jak2/Blog`. This
  closes the project's longest-standing blocker. It first failed with HTTP 403; the
  cause was the fine-grained PAT lacking write, not the app. See the Check access note
  under "Risks to watch".

## Delivered from the 2026-08-25 plan

Eight items raised together, specced as five subsystems plus one blocking bug in
`superpowers/specs/2026-08-25-multi-llm-observability-agent-controls-design.md`.

| Phase | Item | Status |
|---|---|---|
| **0** | On-device LLM produced no output | **Done, verified on device.** Not a hang — 0.43 tok/s behind a buffered API, plus no stop condition. |
| **1** | Per-token generation visibility | **Done, verified on device.** Event stream, live status line, stop button. |
| **2** | Multi-LLM library (adding replaced the last one) | **Done.** `lib/settings/llm_library.dart`, migration from the old single-slot settings, explicit delete. |
| **3a** | Live CPU/RAM | **Done, verified on device.** `/proc/self` is readable on this ROM. Reported as a share of the device, not the `top`-style per-process sum. |
| **3b-c** | Scroll to newest content | **Done.** Uniform via a single `_append` helper, not special-cased. |
| **3d** | Collapsible folders | **Done.** The tree was already real widgets, so no rewrite was needed. |
| **4** | LangChain / graph orchestration | **Partly done.** Both backends are real and tested; the toggles persist config but do **not** yet route generation. The cards say so. |
| **5** | Multi-step task decomposition | **Not started.** The graph engine it depends on is built and tested (`lib/agent/graph_engine.dart`, 15 tests). |

### Beyond the original plan (asked for during the work)

- **Pinning** a repo, folder or file to scope the assistant, enforced app-side by
  `applyPinnedFolder` rather than requested of the model — a 1-1.5B model ignored the
  instruction and copied the prompt's example path verbatim.
- **File creation** by the assistant via a fenced `create-file` block, behind an
  editable confirm card (path and content both editable, shared path validator).
- **New file / New folder** deterministic actions and a repo folder picker.
- **Git action bar** in chat, costing zero prompt tokens.
- **Check access** — a real `git-receive-pack` probe for diagnosing push failures.

### Resolved during implementation

- Chat and Config already share one engine via `OnDeviceEngineRegistry` — the
  duplicate-model-load theory was wrong.
- The folder tree was already widgets, so folding was a small change.
- `/proc/self` is readable on this vivo ROM despite it blocking other `/proc` reads.
- No prior agreed value for Phase 4 loop levels was found in `docs/`; a default of 5
  (range 1-10) was chosen and is configurable via the stepper.

## Open points needing Jaya's input (raised 2026-08-25, autonomous session)

### 1. RESOLVED — the stop-sequence fix is verified on-device

Confirmed on the vivo V2231: replies stop after one turn instead of the model
role-playing a `User:` line. The `-O3` fix was verified in the same session
(0.43 -> ~2.5 tok/s, a full reply in ~14s).

### 1b. PENDING — confirm the dialog-crash fix on device

A `TextEditingController` was disposed at `Navigator.pop` while the route was
still animating out, crashing with `'_dependents.isEmpty': is not true` on
**new folder -> Commit & push**. Fixed by `DisposeWithRoute` (commit `fba5f2f`),
which hands controller ownership to the route; four call sites converted, three
widget tests that genuinely fail against the old pattern.

**Not yet reproduced on device** — the phone was locked when the fix landed. The
trigger needs the field **focused** (the cursor animation re-listens to the
controller), so an unfocused tap will not exercise it. Worth also checking
Config -> Add cloud LLM and Config -> Add/Edit instruction entry, since that
fourth site was never observed crashing.

### 2. On-device inference speed — accept or tune? (still open)

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
- **Routing generation through LangChain.** The adapter is real and tested, but the
  toggle only stores a preference today; chains/agents do not yet drive replies.
- **Phase 5 multi-step decomposition** — cloud-only, hard 5-step cap and token budget.
  The graph engine is built and tested; only the orchestration and UI remain.
- Generic git UI beyond the current bar: diff, merge, history, branch switching and
  creation, per-file staging. (Status, Log, Branches, Pull, Commit & push now exist.)
- Multi-repo / multi-file workflows in a single session.
- Persisting chat history across app restarts.
- **Persisting the selected repo and pin across restarts** — today every relaunch
  means re-selecting a repo before the git bar appears.
- Progress readout during a slow push, and an undo for a written file.
- Automated UI test suite (v1 relies on manual testing against a throwaway repo, plus
  one targeted unit test for the chat-instruction-to-repo-path resolver).

## Risks to watch

- **RESOLVED 2026-08-26 (was the long-standing BLOCKER):** the real clone/push flow
  (git2dart over HTTPS + PAT) has now been executed end-to-end against a live GitHub
  remote from the installed app — a file created in chat was committed and pushed to
  `Jak2/Blog` as `99d3831`. Clone, commit and push are no longer unverified.
- **A push 403 is almost always the token, not the app.** The first live attempt failed
  with `GIT_ERROR_HTTP: 403`. The **Check access** chip diagnoses this definitively by
  probing `GET /<owner>/<repo>.git/info/refs?service=git-receive-pack` (the endpoint a
  push actually uses) with two credential formats. Note the trap it replaced: reading
  `permissions.push` from the REST API reports the *account's* rights on the repo, not
  the *token's*, so a fine-grained PAT with `Contents: Read-only` shows "push granted"
  and still 403s. Never reintroduce that check.
- On-device gguf loading **and inference** are both verified on the vivo V2231.
  gemma-3-1b-Q4 generates at ~2.5 tok/s after the `-O3` fix (0.43 tok/s before it), so a
  sentence takes 10-20s. Usable, and the streaming UI makes the wait legible, but the
  cloud path remains the faster one. **Debug APKs must keep the `-O3` flag from
  `scripts/setup_llama_cpp_dart.sh`** or inference silently returns to unusable.
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
