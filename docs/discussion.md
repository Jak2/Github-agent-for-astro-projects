# Discussion Log — git_agent_app

## 2026-08-23

Initial idea: Android app connecting to GitHub, cloning repos, git-actions UI, pluggable
LLM (local gguf / cloud), chat screen, skills/sub-agents/instructions library, optional
LangChain/LangGraph integration, settings screen for agentic tooling.

User narrowed scope to one v1 task: clone a repo, feed a file's content to an LLM which
restructures it per `structure.md` rules from a bundled instructions set, iterate via
chat until approved, then push the resulting `.md` file to the cloned repo.

Key decisions made through brainstorming (see decision.md for the definitive list):
- Flutter/Dart, reusing `voice_notes_app`'s LLM engine abstraction rather than building
  a new one.
- Real clone + push (not just GitHub REST API file edits) — user was explicit this
  matters for future functionality beyond v1.
- `dart_git` (pure Dart) over libgit2 bindings — avoids native lib/NDK complexity.
- GitHub PAT (not OAuth flow) for v1 — simplest to configure, pasted once in Settings.
- `structure.md` bundled with the app by default, with import-from-local-storage and
  export options — not fetched from inside each cloned repo.
- Input source is the cloned repo's own file tree (browse and pick), not manual
  paste/link entry.
- Chat-style iterative refine loop before push, not a single-shot generation.
- Save path is user-controlled: browse the repo tree to pick a folder, or tell the LLM
  the path in chat — driven by the user's later use case (Astro.js projects where file
  location is meaningful), not app-guessed.
- No fake-engine fallback for the structuring step: if no LLM is configured, block with
  a clear settings prompt rather than risk pushing placeholder content.

Full design: `docs/superpowers/specs/2026-08-23-v1-clone-structure-push-design.md`.

## 2026-08-23 (device test feedback round)

After installing v1 on a physical device, user reported three things:

1. **Bug:** the repo list always showed the download icon and re-prompted to clone
   even for a repo already cloned in a previous visit — no persistence check.
   Fixed same day (see `implementation.md`) — `_load()` now checks each repo's local
   directory on disk before rendering, and an already-cloned repo opens directly
   instead of re-cloning.
2. **Feature ask:** a percentage loading screen while an on-device `.gguf` model
   loads. Investigated `llama_cpp_dart 0.0.9`'s source: its `ModelParams` hardcodes
   libgit2's `progress_callback` to `nullptr` — there is no real progress signal
   available from this library version. Agreed with user to show an honest elapsed-time
   counter ("Loading model… Ns") instead of a fabricated percentage.
3. **Feature ask:** Settings additions for custom skills, sub-agent personas, and
   guardrails — explicitly modeled on Claude Code's skill system (slash-invoked,
   named instruction files). This was previously listed in `status_open_points.md` as
   deferred/out-of-scope for v1; user now wants it built.

Brainstormed and designed both the loading-feedback fix and the skills/personas/
guardrails system together (they touch the same chat screen). Key clarifications from
the user during brainstorming:
- Skills = Claude-Code-style: named, slash-triggered (`/skillname`), one-off addition
  to the next generation only — not a persistent mode switch.
- Personas = role/behavior framing (Code Reviewer, Debugger, Solution Architect,
  Validator, Analyst, SEO Optimizer, Security Analyst were the examples given) —
  selectable as a session default in Settings **and** slash-switchable in chat
  (`/persona:name`), per explicit user request for both.
- Guardrails = always-on constraints applied to every generation, not another
  toggleable skill-like entry.
- User explicitly invited an architect-level second pass on the design rather than
  taking the first sketch as final — see `decision.md` #13 for what changed as a
  result (JSON-manifest library instead of markdown frontmatter, one generic library
  class instead of two, a separate `AgentConfig` model instead of growing
  `EngineSettings`, unambiguous slash-command grammar, bundled starter personas).

Full design: `docs/superpowers/specs/2026-08-23-skills-personas-guardrails-design.md`.

## 2026-08-24 (frontend redesign + repo-aware chat)

User supplied a design mockup (`fronten/Git Agent App Design/git_agent_app.dc.html`)
and asked to fully incorporate it: black/white visual system, bottom-tab nav
(Chat/GitHub/Config) replacing the old single-button Home screen, a one-time
onboarding wizard, and a new General Chat tab. Brainstormed three scope
decisions before writing the spec: General Chat ships as an intentional stub
(no LLM), LangChain/LangGraph toggles are included but inert (an approved
exception to decision.md #12), and the GitHub tab is rebuilt as a literal
flat state machine matching the mockup's own code rather than restyling the
existing `Navigator.push` chain. Full design:
`docs/superpowers/specs/2026-08-23-frontend-redesign-design.md`; implemented
via `docs/superpowers/plans/2026-08-23-frontend-redesign.md` (7 tasks, final
review found real cross-tab integration gaps a per-task reviewer couldn't
see — busy-guard, PAT-retry, hardware back, controller leak — all fixed).

Post-launch device testing surfaced two more issues, fixed same day:
- A real crash (not just cosmetic): `appSecondaryButton`'s
  `SizedBox(width: double.infinity)` used as a direct `Row` child with no
  `Expanded` (the on-device "Choose file" button) threw a `BoxConstraints`
  layout assertion and froze the frame — reproduced only when
  `EngineSettings.choice == EngineChoice.onDevice`, which is exactly what
  the test device had saved, making Config look like it silently went
  blank. Root-caused via `flutter attach`, fixed by giving that button a
  fixed-width wrapper.
- Screen headers rendering under the status bar/notch on three tabs — only
  `OnboardingScreen` had `SafeArea`; added it to the other three.

User then asked for a Models section in Config (load/offload/uninstall an
on-device model, see if it's active) — added `OnDeviceEngineRegistry` as a
shared app-wide engine instance so Config's controls and the chat screen's
actual generation observe the same loaded state, plus `isLoaded`/`load()`/
`unload()` on `OnDeviceLlamaEngine`.

Finally, user asked for General Chat to become repo-aware: real LLM Q&A,
conversational (tap-based) repo/file selection, and answering questions
about repos. Brainstormed the scope down from an initial "feed the whole
repo" ask (real cost/context-window risk) to: tree-only context by default,
file content read on-demand only when explicitly requested via "Ask about
this file," and a "Structure this file" action that hands off to the
GitHub tab's *existing* structuring chat rather than duplicating it. GitHub
tab stays completely unchanged; General Chat becomes a second entry point
into the same repo/file data via new shared, non-UI helpers
(`repo_browser_service.dart`, `file_tree_text.dart`,
`pending_file_handoff.dart`). Full design:
`docs/superpowers/specs/2026-08-24-repo-aware-chat-design.md`.
