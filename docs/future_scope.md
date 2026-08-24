# Future Scope — git_agent_app

## What this app actually is

A mobile agent that clones a repo, reasons about it (cloud or fully
on-device), and can commit/push changes. Most "AI coding assistants" are
desktop/IDE-bound; a phone-native one that works offline is a genuinely
underserved niche (commuting, fieldwork, no-laptop scenarios).

## Where it could grow

1. **On-the-go code review/triage tool** — read a PR diff, ask questions,
   leave comments, all from a phone.
2. **Privacy pitch via on-device-only mode** — for people who can't send
   code to cloud APIs (regulated industries, personal projects with
   secrets).
3. **Broader "explain this codebase to me" tool** — the repo-aware chat
   already built is close to this; it's bigger than just git ops.

## Honest tradeoff

On-device LLM quality on phone hardware (0.5-1.5B models) is weak for real
code reasoning. The load path itself turned out to be fine — the long
"crash/timeout" investigation ended in a version-pin mismatch, not a hardware
limit (see `on_device_load_hang_rootcause.md`) — but the toolchain around it is
brittle: `llama_cpp_dart` 0.0.9 ships bindings that must match an exact
`llama.cpp` commit, with no compile-time check that they do. The cloud-API path
is where the app is actually usable today; on-device is the differentiator but
needs to mature.

**Recommended framing:** mobile git agent, cloud-first, on-device as a
stretch feature — rather than leading with on-device.
