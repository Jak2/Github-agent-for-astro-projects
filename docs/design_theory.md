# Design Theory — git_agent_app

`decision.md` is the ledger: *what* was decided, one row per call. This file is
the theory behind it: the recurring principles those calls came from, and the
visual system they produced. New work should be derivable from this document —
if a decision here doesn't explain a choice you need to make, that's a gap
worth filling rather than a licence to improvise.

Cross-references to `decision.md` rows appear as (#n).

---

## Part 1 — Governing principles

### 1. Honesty over comfort

The app never fabricates a signal it doesn't have. Three separate decisions
came from this one principle:

- **No fake-engine fallback** when the LLM is unconfigured — block with a
  settings prompt instead (#11). `voice_notes_app` ships a fake fallback; that
  is acceptable when the output is a throwaway note and unacceptable when the
  output gets committed and pushed to a real repository.
- **Elapsed-time counter, not a percentage**, on model load (#14). No real
  progress signal exists in `llama_cpp_dart 0.0.9`. A percentage estimated from
  file size would visibly stall or overshoot — a confident lie is worse than an
  honest unknown.
- **Pre-flight file checks** fail loudly and immediately rather than letting a
  missing or truncated `.gguf` surface as a mysterious timeout later.

The corollary, learned the hard way: **a system that hides its errors is worse
than one that fails loudly.** The 300-second "hang"
(`on_device_load_hang_rootcause.md`) was a three-second error concealed by
three layers of well-meant error handling. Handlers that swallow, mask, or
convert errors into timeouts are treated as bugs here, not robustness.

### 2. Verify dependencies by reading their source

Two git libraries were adopted and discarded before `git2dart` (#3). `dart_git`
was visibly stale. `git_on_dart` looked healthy — recent commits, real
documentation — but reading the source during implementation revealed HTTPS
clone and push were non-functional stubs with packfile transfer explicitly
unimplemented.

The rule: for any dependency on the critical path, **read the code that
implements the thing you actually need** before committing to it. Activity
signals, stars, and READMEs describe intent, not behavior. The same principle
later applied to `llama_cpp_dart`, whose own changelog documented a
`llama.cpp` compatibility pin that was wrong for the shipped version.

### 3. Prefer a real implementation over a reimplementation

`git2dart` won because it wraps the actual libgit2 C library rather than
reimplementing the git wire protocol in Dart (#3). Reimplementations of
complex, well-specified protocols are where the stubs hide.

The counterweight is honest: this buys correctness at the cost of an FFI
boundary and native build complexity — which is precisely where this project's
worst bug came from. Accept the native dependency when the alternative is
trusting a pure-Dart reimplementation of something hard; then treat the
version-pinning discipline in Part 3 as mandatory, not optional.

### 4. Reuse the existing thing; don't build a second one

- Engine abstraction ported wholesale from `voice_notes_app` rather than
  rebuilt (#1, #6).
- General Chat's "Structure this file" **hands off** to the GitHub tab's
  existing structuring chat instead of duplicating it (#18).
- Skills and personas are structurally identical, so **one** generic
  `InstructionLibrary` class is instantiated twice rather than written twice
  (#13).

Two implementations of one concept means two places to fix every bug, and they
drift. When a second entry point to the same data is needed, extract a shared
non-UI helper (`repo_browser_service.dart`, `file_tree_text.dart`) and let both
screens call it.

### 5. Let the user be explicit; never guess destructively

Save paths are user-directed — browse and pick, or state the path in chat (#10)
— because Astro.js-style projects are path-sensitive and a wrong guess writes a
file to the wrong place in someone's repository. Input files come from browsing
the cloned repo's real tree (#8) rather than being inferred.

The general form: **when the cost of being wrong is asymmetric — a bad write to
a real repo versus one extra tap — make the user explicit.** Convenience never
justifies a destructive guess.

### 6. Separate concerns before an object becomes a dumping ground

`AgentConfig` is a separate model rather than new fields on `EngineSettings`
(#13). `EngineSettings` covers LLM *connection* config; persona and guardrails
are *behavior* config. Merging them creates a god object that every screen
depends on for unrelated reasons.

Likewise `OnDeviceEngineRegistry` (#17): shared engine *lifecycle* is its own
concern, not something each screen re-derives.

### 7. Strict grammar beats loose heuristics

Slash commands match a strict whole-message grammar (`/skill-slug`,
`/persona:slug`), checked before any other message handling (#13). Loose
matching would collide with ordinary chat text — a real file path being the
obvious case, given that the save-path resolver is already doing heuristic
interpretation of chat messages.

Where two interpreters read the same input, **give the stricter one priority
and an unambiguous grammar**; otherwise the ambiguity surfaces as a rare,
confusing bug.

### 8. Data formats with no fragile parse step

Skills/personas use a JSON manifest plus plain content files, explicitly *not*
markdown frontmatter (#13). A stray `---` inside user-authored content corrupts
frontmatter metadata; a manifest-plus-files layout has no such failure mode.

**Prefer formats where user content cannot be mistaken for structure.**

### 9. Shared state means one instance, not two

Config's model load/offload controls and the chat screen's generation must
observe the *same* engine, or the UI reports a state the app doesn't have
(#17). Two independent instances with independent lifecycles is not a shared
feature — it's two features that look like one.

### 10. Scope discipline, with deliberate exceptions

v1 is one focused pipeline. OAuth, a skills/sub-agent library, framework
switches, and generic git UI are all explicitly out (#12).

The exception is instructive: LangChain/LangGraph toggles ship as **inert UI**
(#16) — visible, non-functional — because the approved mockup shows them and
divergence from the approved design was judged the greater cost. Exceptions to
scope are allowed when named, justified, and recorded. Silent scope creep is
not.

### 11. Fidelity to an approved design over a minimal diff

When the mockup's GitHub tab was a flat state machine and the existing code was
a `Navigator.push` chain, the choice was rebuild-to-match, not restyle (#15) —
the user was offered the lower-risk restyle and chose fidelity.

Once a design is approved, **the design is the specification.** "Closer to what
we already have" is not a reason to diverge from it.

### 12. Context and cost are design constraints

General Chat is tree-only by default; file contents are read on demand, never
preloaded for a whole repo (#18). The original ask was "feed the LLM the whole
repo" — raised as a real context-window and cost risk during brainstorming, and
redirected.

**Treat tokens as a budget with a bill attached**, the way you'd treat memory or
bandwidth.

---

## Part 2 — The visual system

Origin: a user-supplied mockup, fully incorporated (#15). Implemented in
`lib/theme/app_theme.dart`, which is the single source of truth — screens
compose its helpers rather than styling widgets inline.

### Colour: two colours and three greys

```
bg            #000000   pure black      every background
fg            #FFFFFF   pure white      every foreground, every border
muted         #888888                   hint text, secondary labels
divider       #333333                   separators
surfaceMuted  #111111                   subtle raised surfaces
```

**There is no accent colour, and no semantic colour** — no red for errors, no
green for success. This is a deliberate constraint, not an omission. Everything
that would normally be carried by hue is carried by **border, fill inversion,
and type weight** instead.

Consequences to respect when extending:

- Don't introduce an accent to solve a hierarchy problem. Use weight, size, or
  fill inversion — the system already has the vocabulary.
- State is communicated by **fill inversion**: filled (white on black) reads as
  primary/active; outlined (black with white border) reads as secondary/inactive.
- Because nothing depends on hue, the UI is inherently safe for colour-vision
  deficiency. Keep it that way.

### Structure: 2px borders, zero elevation

Every interactive surface is a 2px white border. `elevation: 0` everywhere —
**no shadows anywhere.** With no colour and no shadow, the border is the entire
structural language of the interface: it defines every edge, grouping, and
affordance.

This is why border width is not a free parameter. A 1px or 3px border reads as
a different component, not a variation of the same one.

### Typography: three faces, strict roles

| Face | Role | Default |
|---|---|---|
| **Sora** | Headings and button labels | 24px / w800 heading, 15px / w700 primary button |
| **Inter** | Body and UI text | 13.5px / w400 |
| **JetBrains Mono** | Code, paths, tokens, **all text inputs** | 13px / w400 |

The load-bearing rule: **anything machine-meaningful is monospaced.** Text
fields use `appMono` regardless of content because they hold repo paths, PATs,
endpoints, and model names — strings where character-level precision matters
and where proportional rendering makes `l`/`1`/`I` ambiguous.

### Radius scale

```
10   text fields
12   secondary buttons, icon buttons
14   primary buttons, chat bubbles
3    the "tail" corner of a chat bubble
```

Radius encodes prominence — larger radius for the more prominent control.

### Components

All defined in `app_theme.dart`; use them rather than restyling raw widgets.

- `appBorderedField` — mono text, 2px border in all three states (enabled,
  focused, error). **The border does not change on focus**, consistent with the
  no-colour rule.
- `appPrimaryButton` — filled white on black, Sora w700. Full-width.
- `appSecondaryButton` — outlined, Inter w600. Full-width.
- `appChatBubble` — user messages invert (white fill, black text) and sit right;
  assistant messages are outlined and sit left. The asymmetric 3px tail corner
  marks the speaker. `maxWidth: 320`. `mono: true` for code responses.
- `appIconCircleButton` — fixed 40×40, `filled` toggles the inversion.

**Component contract — a real crash lives here.** `appPrimaryButton` and
`appSecondaryButton` are `SizedBox(width: double.infinity)`. Placing one
directly in a `Row` without an `Expanded` wrapper throws a `BoxConstraints`
assertion and freezes the frame. This shipped once, in Config's on-device
"Choose file" button, and made the whole screen appear to silently go blank —
reproducible only when `EngineChoice.onDevice` was the saved setting. **Wrap
them in `Expanded` or a fixed-width box inside any `Row`.**

### Layout

- Bottom-tab navigation: Chat / GitHub / Config (#15).
- `IndexedStack` keeps tab state alive across switches — which is why
  cross-tab handoffs use `didUpdateWidget`, not `initState` (`initState` fires
  once at app start and will not see a later handoff).
- **`SafeArea` on every screen.** Three tabs shipped without it and rendered
  their headers under the status bar and notch.

---

## Part 3 — Native dependency discipline

Earned from the load-hang investigation; binding on all future work.

1. **The pinned `llama.cpp` commit is part of the source contract.** The
   `llama_cpp_dart 0.0.9` FFI bindings are generated code with no compile-time
   validation against the native structs. A reordered or inserted field in
   `llama_model_params` / `llama_context_params` produces a **silent SIGSEGV at
   runtime, not a build error.**
2. **Before bumping it, diff both param structs** against
   `lib/src/llama_cpp.dart` field-for-field. The method is documented in
   `on_device_load_hang_rootcause.md`.
3. **Patches to the pub-cache live in `scripts/setup_llama_cpp_dart.sh`,** never
   only on a developer's disk. Anything applied outside the repo must be
   scripted, idempotent, and documented — `dart pub cache repair` erases it
   otherwise.
4. **Restore observability before hypothesising.** Eight black-box experiments
   (RAM, storage speed, mmap, OpenMP, release builds, GPU backends) all failed
   while the actual error message sat suppressed. One log callback ended it.
5. **A `Pointer.fromFunction` FFI callback is a diagnostic, never a shipped
   feature.** Routing llama.cpp's log through one crashed the app once
   llama.cpp logged from its own worker thread. Anything durable needs
   `NativeCallable.listener`.

---

## Where the rest lives

- `decision.md` — the numbered decision ledger this document explains
- `discussion.md` — how decisions were reached, in chronological order
- `implementation.md` — what was built, task by task, and the bugs found
- `on_device_load_hang_rootcause.md` — the investigation behind Part 3
- `status_open_points.md` — current status, deferred features, open risks
- `future_scope.md` — where this could grow, and the honest tradeoffs
- `superpowers/specs/` — approved design specs
