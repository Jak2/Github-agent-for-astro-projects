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
- On-device gguf inference performance/memory on target Android hardware is unverified;
  cloud path should be the one exercised first end-to-end.
- **Known limitation, not fixable without a library change:** true percentage-based
  model-load progress is unavailable — `llama_cpp_dart 0.0.9`'s `ModelParams`
  hardcodes libgit2's `progress_callback` to `nullptr`. Working around this with an
  honest elapsed-time counter instead (see the skills/personas/guardrails spec, Part
  1). Revisit only if a future `llama_cpp_dart` release exposes real progress.
