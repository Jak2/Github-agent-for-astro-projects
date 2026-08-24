# Design — Multi-LLM library, generation observability, chat UX, agent controls

**Date:** 2026-08-25
**Status:** Approved (design). Implementation plan to follow.

Eight items were raised together. They are not one project — they are five
independent subsystems plus one blocking bug. This document specifies all of
them, ordered by dependency, so each phase can be built and verified on its
own.

---

## Phase ordering and why

| Phase | Scope | Depends on |
|---|---|---|
| **0** | Silent-LLM bug: generation produces no output | — |
| **1** | Generation observability (per-step/token visibility) | Same code change as Phase 0 |
| **2** | Multi-LLM library (stop replacing saved LLMs) | — |
| **3** | Chat UX: live metrics, scroll behaviour, collapsible folders | — |
| **4** | LangChain/LangGraph controls made real | — |
| **5** | Multi-step task decomposition | Phases 0 and 1 |

Phase 5 is deliberately last. Building orchestration on a generation path that
silently hangs would make every failure ambiguous — is the plan wrong, or is
generation broken?

---

## Phase 0 + 1 — The silent LLM, and making generation observable

### The problem

A query on the on-device engine produces no output at all, silent past ten
minutes, with no error. Confirmed by the user: engine was **on-device (.gguf)**.

### Root cause analysis

The current interface cannot show progress even when it works:

```dart
Future<String> generate(String prompt) async {
  final buffer = StringBuffer();
  final sub = parent.stream.listen(buffer.write);   // accumulates silently
  final promptId = await parent.sendPrompt(prompt);
  await parent.completions
      .firstWhere((event) => event.promptId == promptId)
      .timeout(const Duration(seconds: 120));
  return buffer.toString();                          // returns only at the end
}
```

Tokens *are* streamed by the library into `buffer`, then thrown at the UI in
one lump at completion. On phone-class hardware a small model emits tokens
slowly, so a working generation and a dead hang look identical.

Three concrete suspects, to be confirmed against the running app before the fix
is finalised:

1. **No incremental output** (certain). Even a fully successful generation
   displays nothing until complete.
2. **Engine instance mismatch** (to verify). If the chat screen resolves its own
   `OnDeviceLlamaEngine` rather than the one `Config` loaded via
   `OnDeviceEngineRegistry`, `_ensureLoaded()` triggers a *second* full model
   load inside `generate()` — minutes of work, invisible, possibly with two
   models resident.
3. **Completion event never matches** (to verify). `completions.firstWhere`
   subscribes to a broadcast stream *after* `sendPrompt` is awaited. If the
   completion fires in that window the predicate never matches; the 120s
   timeout should then fire — so if the user saw ten minutes of silence, either
   the timeout did not fire or the resulting error was swallowed by the UI.

That last point matters beyond this bug. **This project has now been bitten
twice by errors converted into silence** (see
`on_device_load_hang_rootcause.md`). Any catch block that discards an error is
treated as a defect here, not as robustness.

### The design

**Extend the engine interface with a stream.** `LlmEngine` gains a streaming
method alongside the existing one; the buffered `generate()` remains for
non-interactive callers (the structuring flow) and is reimplemented on top of
the stream so there is one code path, not two.

```
Stream<GenerationEvent> generateStream(String prompt)
```

`GenerationEvent` is a small sealed/tagged type covering: `status` (a
human-readable stage), `token` (incremental text), `done`, and `error`. Cloud
and on-device engines both emit it — cloud from its HTTP response, on-device
from `LlamaParent.stream`.

**The chat screen renders events as they arrive.** An assistant bubble appears
immediately on send and fills in as tokens stream.

**A visible status line** above or inside that bubble reports the real stage:

```
resolving engine → model loaded ✓ → prompt sent → generating (147 tokens) → done
```

This is the answer to *"I want to know each step so I can tell whether it's
stuck or thinking."* It is derived from real events, never simulated.

**Errors surface, always.** Every failure path renders in the chat as a visible
error message. No silent catch. Timeouts produce a specific message naming the
stage that timed out.

**A stop button** is present while generating.

**Engine identity is made explicit.** The chat screen must use the same
registry instance Config loaded. If a generation would trigger a model load,
the status line says so (`loading model…`) rather than appearing frozen.

### Verification

- Unit tests for the event sequence on a fake engine, including the error and
  timeout paths.
- On-device: confirm tokens appear incrementally, and confirm the status line
  advances during a real query.

---

## Phase 2 — Multi-LLM library

### The problem

Adding an LLM replaces the existing one. The user cannot tell whether the old
one was deleted or merely forgotten — itself a symptom worth fixing.

### The design

A new testable, non-UI unit: `lib/settings/llm_library.dart`.

- An **entry** is either on-device (label + `.gguf` path) or cloud (label +
  endpoint + model name + a reference to its stored secret).
- The library holds a list of entries plus an `activeEntryId`.
- Secrets (API keys, PAT) stay in `flutter_secure_storage`, keyed per entry.
  **Never in `shared_preferences`.**
- Entries are added, listed, activated, and deleted as distinct operations.
  Adding never overwrites.

**Switching models** sets `activeEntryId` and asks `OnDeviceEngineRegistry` to
**unload the previous model before loading the new one** (user's choice: only
one model resident at a time — two loaded models on a phone risks the OS
killing the app).

**Deletion is explicit and honest.** Removing an entry asks whether to also
delete the `.gguf` file from disk, and the UI states plainly which it did. The
current ambiguity ("was it deleted or replaced?") is treated as the bug it is.

Config's Models section becomes a list of saved entries with the active one
marked, rather than a single slot.

### Verification

Unit tests for add/list/activate/delete and round-trip persistence, following
the existing `engine_settings_test.dart` / `agent_config_test.dart` pattern.

---

## Phase 3 — Chat UX

Four independent pieces; each can be built and reviewed separately.

### 3a. Live CPU and RAM

Real device data, **this app's own usage**, read from `/proc/self` via
`dart:io` — no new dependency.

- RAM: resident set size, from `/proc/self/statm` or `VmRSS` in
  `/proc/self/status`.
- CPU%: sampled from `utime + stime` in `/proc/self/stat`, differenced between
  two polls over a known interval.

A small `DeviceMetrics` class owns the polling (roughly 1–2s), is **pausable**
so it does not drain battery when the tab is not visible, and is disposed with
the screen. If a read fails, the readout shows `—`, never a fabricated number.

A process reading its own `/proc` entries is always permitted, but this must be
**confirmed on the physical device** — this ROM has already denied us other
`/proc` reads and a `setprop` this session.

### 3b. Scroll to bottom on repo selection

After a repo is selected — and after any panel or list is inserted into the
chat — the view scrolls to the newest content using the existing
`ScrollController`. Applied uniformly to insertions, not special-cased to one
action.

### 3c. Scroll to the relevant content on icon interaction

Tapping the repository icon or the folder icon scrolls to the content that
action produced, so the result is never off-screen.

### 3d. Collapsible folders

Tapping a folder in the tree folds and unfolds it, to make traversal
manageable.

**Feasibility gate:** this requires the tree to be real widgets over the
`lib/files/file_tree.dart` model. If the tree is currently rendered as a flat
text blob via `file_tree_text.dart`, folding is not a tweak — the display must
be rebuilt as widgets with per-node expanded state. `file_tree_text.dart` and
its tests stay as-is for the text-context path that feeds the LLM; only the
*display* changes. This is confirmed before implementation begins.

---

## Phase 4 — LangChain / LangGraph controls

### The problem

Both are inert toggles (an approved v1 exception, `decision.md` #16). They give
no feedback, no explanation, and no control over iteration depth.

### The design

**Extend `AgentConfig`** — it already follows an immutable `copyWith` +
`SharedPreferences` pattern — with the framework selection and its depth
limits. No parallel settings mechanism.

**A stepper component** is added to `lib/theme/app_theme.dart`, which currently
has no such control:

```
◀   3   ▶     Max reasoning loops
```

Bounded to a sane range, with `HapticFeedback.selectionClick()` on each press
(the app currently uses no haptics anywhere).

**Each card gains a real description** of what the setting does and what
changing it costs — the user's complaint is that the cards convey nothing.

**Honesty requirement.** These controls persist real configuration, but until a
framework backend exists they do not change generation behaviour. The UI must
say so plainly rather than implying an effect it does not have. Fabricating the
appearance of function would violate the project's first principle
(`design_theory.md`, Part 1).

**Open item:** the user recalls a prior discussion fixing the loop levels for
each framework. That discussion is being located in `docs/`; if it exists, its
agreed values are used rather than new ones invented here.

---

## Phase 5 — Multi-step task decomposition

### The user's question, answered

*Is this a good idea, or is this how everything generally works?*

It is a standard pattern — "plan-and-execute" / ReAct. LangGraph exists to do
exactly this. The instinct that it could get expensive is correct, but the
real risk is not the loop.

**The cost risk is context resending, not step count.** If every step resends
the conversation plus all prior step outputs, total tokens grow roughly with
the *square* of the number of steps. The proposed final "consolidate all step
outputs" call is the single most expensive call in the run, because it resends
everything one more time.

### The design

- **Cloud only.** Refused on the on-device engine, with an in-UI explanation:
  0.5–1.5B phone models cannot plan reliably and would burn minutes producing
  incoherent steps.
- **Hard cap of 5 steps.** Not advisory — the loop stops.
- **A hard token budget** that aborts mid-run when exceeded.
- **Confirmation before any multi-step run begins.**
- **A running compact summary** carried between steps instead of resending full
  step outputs — this is the actual defence against quadratic cost.
- **A live token/cost counter** and a **kill switch**, visible throughout.
- Each step's output is displayed as it completes (built directly on Phase 1's
  event stream), followed by the consolidated result.

### Verification

Cost guardrails are tested with a fake engine that counts calls and tokens,
asserting the run aborts at the cap and at the budget. **No live-API test loops
without a hard limit in the test itself.**

---

## Cross-cutting constraints

These apply to every phase and come from `design_theory.md`:

- **Errors are never swallowed.** Every catch either handles meaningfully or
  surfaces visibly. This project has lost two multi-hour debugging sessions to
  masked errors.
- **No fabricated signals.** No estimated percentages, no placeholder metrics,
  no UI implying a function that does not exist.
- **Logic lives in testable non-UI units** (`lib/settings/`, `lib/files/`,
  `lib/chat/`), not inside widgets — matching the existing 15-file test suite.
- **Reuse before adding.** No new dependency where the platform or an existing
  package suffices.
- **`appPrimaryButton` / `appSecondaryButton` are `width: double.infinity`** —
  wrap in `Expanded` inside any `Row`, or the frame throws and the screen
  appears blank.
- **`SafeArea` on every screen.**

## Open items to confirm before implementation

1. Whether the chat screen shares Config's `OnDeviceEngineRegistry` instance
   (decides Phase 0's precise root cause).
2. Whether the folder tree is real widgets or flat text (decides Phase 3d's
   size).
3. Whether a prior agreed value exists for Phase 4's loop levels.
4. `/proc/self` readability on the physical device (Phase 3a).
