# git_agent_app — Repo-Aware General Chat — Design

## Goal

Turn the General Chat tab from a static stub into a real, LLM-backed
assistant that can answer questions about the user's GitHub repos: browse
and select a repo and file conversationally (tappable messages, not
typed commands), see the repo's structure to answer structural questions,
read a specific file on demand to answer questions about it, and hand off to
the existing per-file structuring/push chat when the user wants to actually
restructure a file — all without touching the GitHub tab's existing
behavior.

## Decisions

1. **General Chat and the GitHub tab coexist.** The GitHub tab's
   repos→files→chat flat state machine is unchanged. General Chat becomes a
   second entry point into the same underlying repo/file data, not a
   replacement.
2. **Selection is tap-based, not typed commands.** "Browse repos" and
   "Browse files" are explicit action buttons (same visual slot as the
   GitHub tab's folder icon) that post a tappable list into the chat thread.
   No slash-command or natural-language parsing for selection.
3. **Repo context is tree-only until a file is explicitly opened.** Once a
   repo is selected, the assistant's prompt always includes the repo's full
   name and its file/folder tree rendered as indented text — enough to
   answer structural questions ("what's in docs/", "is there a config
   file") without reading any file content. No file bytes are sent until
   the user asks for a specific file.
4. **Two distinct actions per file, both explicit taps** — resolves the
   tension between "answer questions about a file" (stay in chat) and "open
   the structuring workflow" (go to the GitHub tab):
   - **"Ask about this file"** reads the file's content once and keeps it
     in the General Chat conversation's context indefinitely (until a
     different file is opened or the repo is cleared), so follow-up
     questions about it work without re-reading.
   - **"Structure this file"** hands off to the existing structuring/
     refine/push chat already built into the GitHub tab's flat state
     machine — it does not duplicate that screen. General Chat switches the
     bottom nav to the GitHub tab and that tab opens directly at its chat
     sub-screen for the chosen file, exactly as if the user had navigated
     there by hand.
5. **No upfront full-repo content load.** This corrects the original "feed
   the whole repo" ask once its cost/context-window risk was raised — file
   content is read one file at a time, only when explicitly requested via
   "Ask about this file," never preloaded for every file in the repo.
6. **General Chat drives a real engine.** `buildEngine(settings)` (already
   built) is used exactly as the GitHub tab's chat sub-screen uses it — same
   "block with a Settings prompt if unconfigured" rule, same no-fake-engine-
   fallback constraint that governs the rest of the app. No new engine code
   needed; General Chat was the last screen still using a static stub.

## Architecture

### New shared pieces

**`lib/github/repo_browser_service.dart`** — extracts `GithubTabScreen`'s
existing repo-listing + already-cloned-detection logic (currently private
to `_GithubTabScreenState._loadRepos`) into a reusable function:

```dart
class RepoListResult {
  final List<GithubRepo> repos;
  final Directory reposRoot;
  final Set<String> alreadyClonedFullNames;
}

Future<RepoListResult> loadReposWithCloneStatus(SecretStore secretStore);
```

Both `GithubTabScreen` and `GeneralChatScreen` call this instead of each
implementing their own PAT-read + `GithubApi.listRepos()` + per-repo
`repoDirectory()` existence check. `GithubTabScreen`'s existing clone-on-tap
flow (`RepoGitService.cloneRepo`) is unchanged and not part of this
extraction — only the *listing* logic is shared, since cloning already has
its own well-tested path.

**`lib/files/file_tree_text.dart`** — a pure function:

```dart
String renderFileTreeAsText(FileTreeNode root);
```

Walks the tree (same structure `buildFileTree` already produces) and
renders it as indented lines, e.g.:

```
README.md
docs/
  posts/
src/
  main.dart
  config.dart
```

Directories get a trailing `/`; nesting is shown via two-space indent per
depth level. This is the only repo-structure information sent to the LLM
before a specific file is opened.

**`lib/chat/pending_file_handoff.dart`** — a small app-wide holder, the same
pattern as `OnDeviceEngineRegistry`:

```dart
class PendingFileHandoff {
  PendingFileHandoff._();
  static final PendingFileHandoff instance = PendingFileHandoff._();

  ({GithubRepo repo, Directory repoDir, String relativePath, String content})? _pending;

  void request({required GithubRepo repo, required Directory repoDir, required String relativePath, required String content});
  ({GithubRepo repo, Directory repoDir, String relativePath, String content})? consume(); // returns and clears
}
```

`GeneralChatScreen`'s "Structure this file" action calls `request(...)`,
then asks `RootScreen` to switch the active tab to GitHub (see below).
`GithubTabScreen` checks `PendingFileHandoff.instance.consume()` when it
becomes the visible tab (via `didChangeDependencies` or an
`AutomaticKeepAliveClientMixin`-safe visibility check — the implementation
plan picks the exact hook) and, if non-null, sets its own
`_activeRepo`/`_activeRepoDir`/`_activeFilePath`/`_activeFileContent` and
`_subScreen = _SubScreen.chat` directly, then runs its existing
`_initChat()` — reusing 100% of the GitHub tab's already-built structuring
chat with no duplication.

### RootScreen change

`RootScreen` gains a way for a tab to switch to another tab index. Simplest
form: pass a `void Function(int index) onSwitchTab` callback down to
`GeneralChatScreen` (RootScreen already owns `_tabIndex` and `setState`).
No new state management library — this is one callback, one setState.

### GeneralChatScreen rewrite

New state (replacing the current stub's plain message list):

- `LlmEngine? _engine` — built via `buildEngine(settings)` in `initState`,
  same unconfigured-engine block-and-message pattern as the GitHub tab's
  chat.
- `GithubRepo? _activeRepo`, `Directory? _activeRepoDir`,
  `FileTreeNode? _fileTree` — set once a repo is selected via the tappable
  repo list; cleared has no explicit UI in v1 (selecting a different repo
  just replaces them — no "clear repo" action needed for this scope).
- `String? _openFilePath`, `String? _openFileContent` — set by "Ask about
  this file"; persists across turns until a different file is opened.
- Prompt construction for each turn:
  - No repo selected: just the running conversation, sent to `_engine`.
  - Repo selected, no file open: conversation + a system-style prefix line
    with the repo's full name and `renderFileTreeAsText(_fileTree!)`.
  - Repo selected, file open: the above plus the open file's relative path
    and content appended.
- "Browse repos" button: calls `loadReposWithCloneStatus`, posts a message
  whose body is a list of tappable repo rows (already-cloned vs
  not-yet-cloned shown the same way the GitHub tab shows them — tapping a
  not-yet-cloned repo clones it first via the existing `RepoGitService`,
  identical to the GitHub tab's behavior, so General Chat can select repos
  it hasn't cloned yet too).
- "Browse files" button (only enabled once a repo is selected): calls
  `buildFileTree(_activeRepoDir!)`, posts a tappable file/folder list.
  Tapping a file shows the two actions described in Decision 4; tapping a
  folder expands/browses into it (same recursive tile pattern already used
  by `GithubTabScreen._fileTiles`).

## What's explicitly out of scope

- Typed/slash-command repo or file selection in General Chat (Decision 2).
- Preloading or ever sending whole-repo file contents (Decision 5).
- A "clear selected repo" affordance — v1 only supports replacing the
  selection by browsing again.
- Any change to the GitHub tab's own behavior, styling, or state machine
  beyond the one new "check for a pending handoff" hook.
- Multi-repo context in a single conversation — General Chat holds exactly
  one active repo at a time, same as the GitHub tab.

## Testing

- `renderFileTreeAsText`: pure function, straightforward unit tests
  (empty tree, nested dirs, files-only, ordering).
- `loadReposWithCloneStatus`: extracted from already-manually-verified
  logic; a real unit test wasn't written for the original private method
  (UI-screen convention in this codebase), and extraction doesn't change
  that — this function lives in `lib/github/`, not `lib/ui/`, so it CAN be
  unit-tested with a fake `SecretStore`/mocked `Dio` the way
  `github_api_test.dart` already does; the plan should include this test
  since it's now a standalone, non-UI unit.
- `PendingFileHandoff`: trivial request/consume/clear semantics, worth a
  short unit test (set → consume returns it once → second consume returns
  null).
- `GeneralChatScreen` and the `GithubTabScreen` handoff-consumption hook:
  no unit tests, matching this codebase's UI-screen convention — verified
  via `flutter analyze` and a manual on-device smoke test (browse repos,
  select one, browse files, ask about a file, then structure a file and
  confirm it lands in the GitHub tab's chat with that file loaded).
