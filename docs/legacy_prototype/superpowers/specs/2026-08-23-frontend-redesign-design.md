# git_agent_app — Frontend Redesign — Design

## Goal

Rebuild the app's UI to match the design mockup at
`my_learning_projects/git_agent_app/fronten/Git Agent App Design/git_agent_app.dc.html`
(a static HTML/JS prototype, not shipped code) — a black/white visual system,
bottom-tab navigation, an onboarding wizard, and a new stub general-chat tab
— replacing the app's current default-Material look and push-navigation.

## Source of truth

The mockup file is the literal spec for markup structure, copy, spacing, and
behavior. This design doc records the decisions needed to port it onto real
Flutter state and the existing engine/git/instruction-library backend rather
than the mockup's fake `setTimeout`-based stand-ins — it does not repeat the
mockup's visual details, which the implementation plan will read directly
from the mockup file.

## Decisions

1. **General "Chat" tab is a stub**, matching the mockup exactly: a static
   assistant message ("Ask me anything about your repos, or open a file from
   the GitHub tab to structure it.") and an input that, on send, always
   replies with a canned redirect message. No LLM call, no persistence. This
   keeps the new tab's scope to a UI shell only.
2. **LangChain/LangGraph toggles are included as inert UI**, matching the
   mockup exactly: two toggle switches in Settings with no backend and no
   persistence. This is a deliberate exception to decision.md #12 (v1
   excludes framework switches) — the toggle exists visually per the
   approved design but flips no real behavior, tracked as a known gap below.
3. **GitHub tab is a flat state machine**, matching the mockup's actual
   code: one `GithubTabScreen` widget holding `_subScreen` state
   (`repos | files | chat`) that swaps content in place, not
   `Navigator.push` between three routes. This replaces
   `RepoListScreen`/`FileBrowserScreen`/`ChatScreen`'s current push-based
   wiring. Back navigation is handled by explicit back buttons
   (`goBackToRepos`, `goBackToFiles`) that set `_subScreen`, exactly as in
   the mockup — not Flutter's route stack.
4. **Onboarding is a one-time wizard**, gated by a new persisted
   `onboarded: bool` (SharedPreferences, default `false`). Unonboarded users
   see the 3-step wizard (PAT → repos-preview-or-skip → LLM engine choice)
   on every app launch until they finish or the flag is set; onboarded users
   go straight to the tabbed app. The wizard's PAT and LLM fields write to
   the same `SecretStore`/`EngineSettings` the existing Settings screen
   already uses — it's a guided first pass at the same config, not a
   separate store.
5. **Bottom nav replaces the current Home screen.** `main.dart`'s
   `HomeScreen` (button-based launcher) is removed. The new root widget is:
   onboarding wizard if `!onboarded`, else a 3-tab `Scaffold` with
   `Chat | GitHub | Config` matching the mockup's bottom bar exactly
   (icons, labels, active/inactive color).
6. **Visual system applies app-wide**: black (`#000`) background, white
   2-3px borders, hard offset drop-shadows on primary buttons, `Sora`
   (headings), `Inter` (body/UI), `JetBrains Mono` (paths, code, technical
   labels) via `google_fonts` package (new dependency — the mockup loads
   these from Google Fonts CDN, which isn't an option in a native app).
   Existing screens (Settings' skills/personas/guardrails sections built in
   the prior plan, chat bubbles, repo/file lists) are restyled to match, not
   rewritten from scratch — same widgets, new `ThemeData`/inline styles.
7. **Existing backend logic is preserved as-is.** `InstructionLibrary`,
   `AgentConfig`, `EngineSettings`, `SecretStore`, `RepoGitService`,
   `buildStructuringPrompt`, slash-command parsing, the on-device load timer
   — none of this changes. This plan is UI/navigation/theme only.

## Screen inventory (mapped to mockup sections)

| Mockup section | Real widget | Notes |
|---|---|---|
| Onboarding (3 steps + repos preview overlay) | `OnboardingScreen` (new) | PAT step, repos-intro step (with "Browse your repositories" preview overlay, skippable), LLM step (cloud/on-device radio, same fields as Settings) |
| Bottom nav + tab switch | `RootScreen` (new, replaces `HomeScreen`) | 3 `IndexedStack`-or-equivalent tabs: Chat, GitHub, Config |
| Chat tab (general) | `GeneralChatScreen` (new, stub) | Static message list + input, canned reply only |
| GitHub tab — repos sub-screen | `GithubTabScreen` (rewrite of `RepoListScreen`, folded in) | Existing clone/already-cloned logic preserved, restyled |
| GitHub tab — files sub-screen | same `GithubTabScreen`, `_subScreen='files'` (rewrite of `FileBrowserScreen`, folded in) | Existing file-tree logic preserved, restyled |
| GitHub tab — chat sub-screen | same `GithubTabScreen`, `_subScreen='chat'` (rewrite of `ChatScreen`, folded in) | All existing chat/generate/push/slash-command/persona-badge/load-timer/folder-sheet/toast logic preserved, restyled |
| Config tab | `ConfigScreen` (rewrite of `SettingsScreen`) | Same fields/sections (PAT, engine, structure.md, skills, personas, guardrails) plus the new inert LangChain/LangGraph toggles, restyled |

## What's explicitly out of scope

- Any new backend capability (general chat's real LLM wiring, LangChain/
  LangGraph actually doing something) — both are visual-only per the
  decisions above.
- Changing `InstructionLibrary`/`AgentConfig`/engine/git logic.
- Tablet/landscape layout — mockup is a fixed phone-width mock, port as
  phone-portrait only, matching the app's existing scope.
- Animations beyond what the mockup already specifies (spin, slide, toggle
  transition) — those are part of the visual spec and are in scope.

## Known gap (tracked, not fixed here)

LangChain/LangGraph toggles are inert UI with no backing state — a user can
flip them and see no effect, and the toggle position doesn't even persist
across app restarts (the mockup doesn't persist it either). This is accepted per
decision #2 above; flagged in `status_open_points.md` as a real gap if this
surfaces in future user feedback.
