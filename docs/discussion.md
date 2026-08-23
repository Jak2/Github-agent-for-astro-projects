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
