# git_agent_app — Skills, Personas, Guardrails + On-device Load Feedback — Design

## Goal

Two independent additions on top of v1:

1. **Agentic configuration for the structuring LLM**: named, reusable "skills"
   (Claude-Code-style, slash-invoked one-off actions), "personas" (role/behavior
   framing, selectable as a session default or slash-switched), and "guardrails"
   (always-on constraints applied to every generation).
2. **Honest loading feedback for the on-device engine**: an elapsed-time indicator
   while the local `.gguf` model loads, since the installed `llama_cpp_dart` version
   cannot report a true load percentage.

## Part 1: On-device model load feedback

**Constraint discovered:** `llama_cpp_dart 0.0.9`'s `ModelParams` hardcodes libgit2's
`progress_callback` to `nullptr` — there is no hook in this library version to observe
real load progress. A fabricated percentage would be actively misleading.

**Design:** `chat_screen.dart` starts a `Timer.periodic(Duration(seconds: 1))` the
moment it detects the active engine is `OnDeviceLlamaEngine` and this is the *first*
`generate()` call in the session (i.e. the model hasn't loaded yet). While that timer
runs, the busy indicator area shows "Loading model… Ns" instead of the generic
progress bar. The timer is cancelled the instant `generate()` returns (success or
error) and is properly disposed if the screen is torn down mid-load.

No percentage, no fake progress bar fill — an honest elapsed-time counter only.

## Part 2: Skills, Personas, Guardrails

### Data model

A **named instruction** is the shared shape behind both skills and personas:
`{ slug, name, description, content }`. `slug` is the lowercase-kebab identifier used
in slash commands (e.g. `code-reviewer`); `name`/`description` are display strings;
`content` is the markdown instruction body.

**Storage:** one JSON manifest file per library (`skills_manifest.json`,
`personas_manifest.json`) mapping `slug -> {name, description}`, plus one `.md`
content file per entry named `<slug>.md`, all under a per-library subdirectory of app
storage (`.../skills/`, `.../personas/`). Metadata lives only in the manifest — content
files are never parsed for structure, so editing content can never corrupt metadata.

**`InstructionLibrary`** (one class, instantiated twice — once per category):
```
class InstructionLibrary {
  InstructionLibrary({required Directory root});
  Future<List<InstructionEntry>> list();
  Future<InstructionEntry> add({required String name, required String description, required String content});
  Future<void> update(String slug, {String? name, String? description, String? content});
  Future<void> delete(String slug);
  Future<String?> contentFor(String slug); // null if slug doesn't exist
}
```
`add()` slugifies `name` and rejects (throws) on a slug collision — no silent
overwrite. `delete()` on a nonexistent slug is a no-op.

**`AgentConfig`** (separate from `EngineSettings` — behavior config vs. connection
config):
```
class AgentConfig {
  final String? defaultPersonaSlug; // null = no persona by default
  final String guardrails;          // free text, one rule per line, '' = none
  static Future<AgentConfig> load(SharedPreferences prefs);
  Future<void> save(SharedPreferences prefs);
}
```

**Bundled starter personas:** shipped as assets (same pattern as `structure.md`) and
copied into the personas library on first run if the library is empty: Code Reviewer,
Debugger, Solution Architect, Validator, Analyst, SEO Optimizer, Security Analyst.
Each a short markdown file describing that role's thinking approach. Users can edit or
delete any of them like their own entries — nothing is protected/read-only.

### Settings screen

Two new sections plus one new field:

- **Skills** — list of `name` + `description` rows, each with Edit / Delete. "Add"
  opens a form (name, description, content). No slash-prefix typed by the user here —
  the slug is derived automatically from the name.
- **Personas** — same list UI (Add / Edit / Delete), plus a dropdown "Default
  persona" bound to `AgentConfig.defaultPersonaSlug` (options: "None" + every persona
  in the library).
- **Guardrails** — one multi-line `TextField` bound to `AgentConfig.guardrails`.

All three save via the existing Settings "Save" button, alongside PAT/engine
settings.

### Chat screen: slash commands

Grammar (checked in `_send()` **before** the existing refinement/save-path branch):
a message is a slash command only if trimmed and the first character is `/`, matching
`^/([a-z0-9-]+)(:([a-z0-9-]+))?$` on the whole trimmed string (no trailing text) — a
message that merely *contains* a slash elsewhere, or has other words around it, is
never treated as a command and falls through to the existing refinement/save-path
logic unchanged.

- `/skill-slug` — looks up in the Skills library. Found: appended as a one-time
  addition to the next `buildStructuringPrompt` call (consumed once, like a
  refinement, then cleared), confirmation message shown, triggers regeneration. Not
  found: chat error message, no regeneration, no crash.
- `/persona:slug` — looks up in the Personas library. Found: sets a session-local
  `_activePersonaSlug` field (in-memory only, per the existing "no chat persistence"
  rule — never written back to `AgentConfig`), confirmation message shown, does
  **not** itself trigger regeneration (affects the next refinement/regen). Not found:
  chat error message.
- Deleting a persona/skill that's currently active (session override or
  `AgentConfig` default) fails safe: the reference is dropped, prompt composition
  proceeds as if none was set — never a crash or a stale-content bug.

### Prompt composition

`buildStructuringPrompt` gains three new optional named parameters (all default to
empty, so existing call sites and existing tests are unaffected):
```
String buildStructuringPrompt({
  required String structureRules,
  required String sourceContent,
  required List<String> refinementRequests,
  String guardrails = '',
  String? personaContent,
  String? skillContent,
});
```
Composition order in the built prompt: guardrails → persona content → base structure
rules → one-time skill content → source content → refinement requests. Guardrails are
outermost (safety floor), skill content is innermost/most recent (freshest one-off
instruction).

## Testing

- `InstructionLibrary`: real temp-directory tests — add/list/update/delete,
  duplicate-name rejection, delete-of-nonexistent-slug no-op, manifest/content-file
  consistency after each operation.
- Slash-command parser (pure function, extracted from `_send()`'s logic so it's
  testable in isolation): valid skill slug, valid persona slug, message that merely
  contains a slash but doesn't start with one, message starting with `/` but with
  trailing words (not a bare command), unknown-format edge cases.
- `AgentConfig`: load/save round-trip, same pattern as `EngineSettings`'s test.
- `buildStructuringPrompt`: new tests asserting composition order when
  guardrails/persona/skill are all present together, and that omitting them
  reproduces the exact prior output (regression safety for existing behavior).
- On-device load timer: not unit-tested (UI timing behavior) — manually verified
  during the next on-device engine smoke test.

## Explicitly out of scope

- Real multi-agent orchestration — personas only change the prompt text sent to the
  single LLM call this app makes; there is still exactly one model invocation per
  generation.
- Exporting/importing a bundled "skill pack" (multiple entries as one file).
- Versioning or edit history for skills/personas.
- A true percentage-based model-load progress bar — blocked on the installed
  `llama_cpp_dart` version's disabled progress callback (see Part 1).
