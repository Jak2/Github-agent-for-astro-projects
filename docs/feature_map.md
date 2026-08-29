# PocketGit — Feature Map

**What each feature is, where it lives in the app, how it behaves, and how it looks.**

PocketGit is a phone-sized GitHub client with one job: *see your repositories, write a
file, push it.* Everything below is deterministic git or file work behind a button. There
is no AI, no chat, no background sync.

- **Package:** `pocket_git` · **Android id:** `com.jayaarunkumar.pocketgit` · **Label:** PocketGit
- **Engine:** real libgit2 through `git2dart` FFI + GitHub REST over `dio`
- **Source:** `lib/` — 3.5k lines · **Tests:** 95 passing

---

## 1. Design language

The whole app is one visual system, defined once in [`lib/theme/app_theme.dart`](../lib/theme/app_theme.dart)
and used everywhere. No screen styles itself.

### 1.1 Palette and type

| Token | Value | Used for |
|---|---|---|
| `AppColors.bg` | pure black | every surface, including dialogs |
| `AppColors.fg` | pure white | text, icons, all 2px borders |
| `AppColors.muted` | `#888888` | secondary text, disabled state |
| `AppColors.divider` | `#333333` | hairlines between regions |
| `AppColors.surfaceMuted` | `#111111` | inset strips |

Three typefaces, each with a fixed job:

- **Sora** (`appHeading`) — screen titles, section titles, button labels.
- **Inter** (`appBody`) — sentences: explanations, warnings, empty states.
- **JetBrains Mono** (`appMono`) — anything that is *data*: repo names, paths, branches,
  git output, commit SHAs, token hints.

The rule is legible on sight: **if git or the filesystem produced it, it is monospace.**

### 1.2 Component kit

| Component | Look | Where it is used |
|---|---|---|
| `appPrimaryButton` | filled white, black text, 14px radius, full width | the one committing action per surface |
| `appSecondaryButton` | black fill, 2px white border, full width | reversible/secondary actions |
| `appActionChip` | compact bordered pill, icon + mono label; `emphasis: true` inverts it to filled white | action bars, popup choice lists |
| `appIconCircleButton` | 40×40 bordered square-ish button | back, refresh |
| `appBorderedField` | black fill, 2px white border, mono text | every text input |

Disabled state is expressed by switching border and text to `muted`, never by opacity —
a chip that is off still reads as a chip.

### 1.3 Popups are the only output surface

This is the app's defining interaction decision. The old codebase this was built from
printed everything into a chat log; **PocketGit has no scrollback**, so a git result, a
refusal and a crash all arrive in the same framed card, and the user never has to scroll
back to find out what happened.

Three popups, all sharing `_dialogFrame` (black card, 2px white border, 14px radius):

| Popup | Shape | Purpose |
|---|---|---|
| `showOutputPopup` | scrollable **selectable** mono text + a single **Close** | read-only result: `git status`, a log, a diff, an access verdict, an error |
| `showConfirmPopup` | optional mono `detail` line, muted explanation, **Cancel / Confirm** | any destructive or outward-facing action. Returns `false` on dismiss — never treats a stray tap as consent |
| `showInputPopup` | description + bordered field + live validator message, **Cancel / Confirm** | one value: a path, a branch name, file content, the token (`obscure: true` masks it) |

**`AppControllerScope`** ([app_theme.dart:233](../lib/theme/app_theme.dart#L233)) backs every
popup that has a field: the *route* owns the `TextEditingController` and disposes it when the
route unmounts. Disposing it when `showDialog`'s future completes is a real crash — the field
keeps rebuilding through the close animation and reads a dead controller
(`A TextEditingController was used after being disposed` → framework assert → red screen).
Guarded by `test/ui/dialog_controller_test.dart`.

---

## 2. Navigation shell

**File:** [`lib/ui/root_screen.dart`](../lib/ui/root_screen.dart) · entered from
[`lib/main.dart`](../lib/main.dart) after `PlatformSpecific.initialize()` loads libgit2.

Two tabs, an `IndexedStack` so each keeps its scroll position, with a custom bottom bar
(2px white top border, icon over a 10px mono label, muted when inactive):

| Tab | Icon | Screen |
|---|---|---|
| **Repos** | `folder_copy_outlined` | `ReposScreen` — the home surface |
| **Settings** | `tune` | `SettingsScreen` — the account |

There is no onboarding flow. A missing token is expressed as an empty state on the Repos
tab that points at Settings — one less screen to maintain, and no wizard to sit through
after a reinstall.

**Account epoch:** Settings hands `onAccountChanged` upward; RootScreen increments a counter
used as `ValueKey` on the repos tab, so signing in or out rebuilds the repo list from scratch
instead of leaving the previous account's rows on screen.

---

## 3. Repositories tab

**File:** [`lib/ui/repos_screen.dart`](../lib/ui/repos_screen.dart)

### 3.1 Layout

```
Repositories                                   (⟳)     ← Sora 22 + refresh button
[ Filter repositories                          ]       ← bordered field, live filter
──────────────────────────────────────────────────
[▣] owner/repo-name                          (⋯)      ← rows, pull-to-refresh
    cloned · main
[▢] owner/other-repo                                    
    not cloned · master
```

### 3.2 The list

Loaded by `loadReposWithCloneStatus` — GitHub's `/user/repos` **followed across pages**
(100 per page, up to 10 pages) intersected with what is on disk. Sorted by GitHub's
`updated`, so the repo worked on last is at the top.

**Row anatomy:** a 36×36 bordered tile on the left, inverted to filled-white when the repo is
cloned (`folder_open` icon) and outline when it is not (`cloud_download_outlined`); the full
name in mono; a muted second line reading `cloned · <default branch>` or
`not cloned · <default branch>`. While that row is cloning, the tile becomes a spinner and
the subtitle switches to a progress line — and every other row goes inert, because two
clones into the same storage should not race.

**Filter:** plain client-side `contains` over the full name. It filters what was fetched,
which is why pagination matters — the box would otherwise silently hide repos past the 100th.

### 3.3 States

| State | What is shown |
|---|---|
| Loading | centred white spinner |
| **No token** | `link_off` icon, "Connect your GitHub account", **Open settings** → jumps to the Settings tab |
| **Error** | `error_outline`, the message, **Retry** |
| Empty / filtered to nothing | a muted line, still inside a `ListView` so pull-to-refresh keeps working |

### 3.4 Actions

- **Tap a not-cloned repo** → `showConfirmPopup` naming the repo and branch and saying it
  downloads into app storage → clones → opens it.
- **Tap a cloned repo** → opens immediately.
- **Tap ⋯ / long-press a cloned repo** → **Local clone** popup with three choices: *Open*,
  *Re-clone*, *Delete local clone*. It is a bespoke three-way dialog rather than a confirm
  popup on purpose: mapping "Re-clone" onto a Cancel button would let a stray tap outside the
  dialog destroy a working tree. Both destructive options then pass through their own confirm,
  worded to say uncommitted work is lost and that **nothing on GitHub is touched**.
  A failed delete aborts the re-clone rather than cloning over a directory that is still there.

### 3.5 Failure reporting

One `_report()` path: read the token, `redactSecrets(message, token:)`, prepend
`githubAuthHelp()` when GitHub returned 401/403, show it in an output popup. The token is
never held in widget state and never rendered.

---

## 4. Repository screen — the workbench

**File:** [`lib/ui/repo_screen.dart`](../lib/ui/repo_screen.dart) · pushed as a full route from
a repo row.

### 4.1 Layout

```
(←)  owner/repo-name                        [⑂ main]   ← header, branch chip
[Status][Log][Diff][Branches][Pull][Commit & push][Check access]   ← scrolls sideways
Uncommitted  [notes.md] [README.md]                     ← only when dirty
──────────────────────────────────────────────────
▸ 📁 docs                                               ← file tree, collapsed
▾ 📁 lib
    📄 main.dart
  📄 README.md
──────────────────────────────────────────────────
[      New file      ] [    Import file     ]
```

### 4.2 Header and branch chip

Back button, repo full name in Sora, and the current branch as an `appActionChip` — the chip
*is* the branch switcher. Until the first refresh completes it shows the repo's default branch
rather than an empty gap.

### 4.3 Git action bar

Horizontally scrollable so a narrow phone scrolls instead of overflowing. Every chip is
disabled while a git operation is in flight, so two pushes cannot overlap on one clone.

| Chip | Runs | Result |
|---|---|---|
| **Status** | `statusLines` | `$ git status` popup, `XY path` format; a clean tree says `working tree clean` out loud rather than showing an empty card |
| **Log** | `recentCommits(limit: 10)` | `abc1234  subject` + author and relative date |
| **Diff** | `diffLines` | unified patch text; `no changes` when clean |
| **Branches** | `branchLines` | the branch popup (§4.4) |
| **Pull** | `pullFastForward` | fast-forward only — refuses on divergence and on a dirty tree, both with a written explanation |
| **Commit & push** | the commit flow (§4.6) | *filled white* — the only chip that publishes outward |
| **Check access** | GitHub REST `/user` + `/repos/:full_name` | says whether the token is valid, what scopes it reports, and whether push is granted — the answer libgit2 cannot give, which only ever says "403" |

### 4.4 Branch popup

Lists local branches (checked-out one marked `*`) plus a **New branch…** row, as a column of
chips. Choosing a branch runs `checkoutBranch`, which refuses on a dirty tree because a forced
checkout eats uncommitted work. Choosing New branch asks for a name and runs
`createBranch(checkout: true)`, which carries pending work along exactly like `git checkout -b`.

### 4.5 Uncommitted bar

Appears only when the tree is dirty. One chip per pending path, basename only, with the full
path in a tooltip. Tapping one opens a four-way popup:

| Choice | Behaviour |
|---|---|
| **Edit** | the file editor (§4.7) |
| **Diff** | `git diff` for just that path |
| **Discard changes** | confirm first — restores the path to the last commit, destroying uncommitted work |
| **Delete file** | confirm first — removes it from the clone |

### 4.6 Commit & push

The app's whole point, so it is the most gated path:

1. **Token check** → "Not connected" popup pointing at Settings.
2. **Identity check** → `loadCommitIdentity`; missing means no account is connected, and the
   commit author *is* the signed-in GitHub account, so it stops here too.
3. **Confirmation popup** showing `owner/repo · branch`, the count and list of paths (capped
   at 60 lines, scrolling inside a 120px box so a 200-file commit cannot push the buttons off
   screen), and an editable message defaulting to `Update from PocketGit`.
4. **Commit** — everything (`commitAllAndPush`) from the toolbar, or exactly one path
   (`commitFilesAndPush`) when the flow started from a single file.
5. **Result popup**. On failure: `githubAuthHelp` first, then the raw error with the token
   scrubbed, then an offer to **Retry push** — which calls `pushCurrentBranch` and creates no
   second commit, for the case where the commit landed but the network did not.

### 4.7 File tree and editor

The tree is built from the clone on disk (`.git` skipped), rendered as indented rows with a
chevron, a folder/file icon, and the name in mono. **Everything below the root starts
collapsed** — a repo with `node_modules` in it must not open as a thousand-row list.

Tapping a file:

1. `looksBinary` (NUL byte in the first 8KB) → refusal popup: *saving it back would corrupt it*.
2. Content is read **before** the dialog opens, so a read failure is a popup rather than an
   empty editor pretending the file is blank.
3. The editor popup shows the path in mono over a 12-line field that scrolls internally, with
   **Rename** and **Delete** chips inside it and **Cancel / Save** below. The dialog hands back
   `(action, text)` together, so nothing is read off a controller after the route is gone.
4. Save writes to the clone and says plainly: *local clone only — Commit & push to publish it*.
   Rename validates the new path live and confirms before overwriting. Delete confirms first.

### 4.8 New file — the headline feature

Bottom bar, filled white, always reachable:

1. **Path popup** — validated on every keystroke by `filePathRejection`; the reason
   (`paths may not escape the repository`, `writing inside .git is not allowed`, …) appears
   under the field and the confirm button stays inert until it is a legal path.
2. **Overwrite confirm** if something is already there.
3. **Content popup** — a 10-line field.
4. **Write** into the clone, then **"Commit & push now?"** — accepting commits *just that file*
   and pushes it, which is the shortest path from "I want to write something" to "it is on
   GitHub".

### 4.9 Import file

`Import file` (secondary button) opens the system picker, asks where it should land inside the
repo (defaulting to the picked file's basename, validated the same way), confirms an overwrite,
copies the bytes, and reports the source → target mapping.

### 4.10 The error funnel

`_runGitAction` is the single spine every action runs through:

- sets the busy flag and clears it in `finally`,
- reads the token **only** so the catch blocks can scrub it out of libgit2's message,
- treats `StateError` as *our own refusal* — already written for a human, shown verbatim,
- treats anything else as a real failure — `githubAuthHelp` first, then the raw text redacted,
- refreshes branch, pending paths and tree afterwards, whatever happened.

No code path can swallow an error, and no code path can put the token on screen.

---

## 5. Settings tab

**File:** [`lib/ui/settings_screen.dart`](../lib/ui/settings_screen.dart) · four sections,
each a titled block with a hairline divider.

### 5.1 GitHub account

Shows `@login`, the account name and the email commits will carry, or **Not connected.**

- **Connect / Replace token** → masked input popup (`obscure: true`) → the token is
  **validated against `/user` before it is written**: a token GitHub rejects never reaches the
  keystore. On success it stores the PAT, caches the identity, bumps the account epoch, and
  confirms with the login it connected as. If storing succeeded but caching the identity did
  not, the message says so instead of claiming nothing was saved.
- **Sign out** → confirm → deletes the secret and the cached identity. Clones stay on disk;
  the popup says so.
- A "Talking to GitHub…" line replaces the buttons while a call is in flight.

### 5.2 Commit identity

Read-only: *Commits are authored as `<name> <email>`*, plus one muted line explaining it comes
from the signed-in GitHub account and is not editable here. **Refresh from GitHub** re-reads
`/user` and re-saves. Accounts that hide their email fall back to GitHub's own
`{id}+{login}@users.noreply.github.com`, so commits still attribute correctly.

### 5.3 Token help

A button opening an output popup covering: classic token with the `repo` scope, fine-grained
token with *Contents: Read and write*, where to generate one, what expiry means (it shows up
later as HTTP 401), and that the token is stored in the device keystore.

### 5.4 About

Name, version, and one line on what the app does.

---

## 6. Behind the screens

### 6.1 Git engine — `lib/git/repo_git_service.dart`

Every operation opens the repository, works, and frees the handle in `finally`.

| Method | Note |
|---|---|
| `cloneRepo` | deletes the target first; **cleans up the directory if the clone fails**, so a half-written folder cannot read as "cloned" forever |
| `statusLines` / `uncommittedPaths` | merge libgit2's status with an index-to-workdir diff, because the default status omits untracked files — a Status button blind to a new file is worse than no button |
| `commitAllAndPush` / `commitFilesAndPush` | stage, commit with the GitHub identity, push; **no parent commit on an unborn HEAD**, so the first commit into an empty repo works |
| `pushCurrentBranch` | push with no new commit — the retry path |
| `createBranch` / `checkoutBranch` | create carries pending work; switch refuses a dirty tree |
| `discardChanges` | untracked → delete; tracked → checkout HEAD for that path |
| `diffLines` | full patch, or filtered to one path |
| `pullFastForward` | fetch, analyse, fast-forward — never merges; the dirty check counts untracked files, since a forced checkout would overwrite them |
| `deleteLocalClone` | removes the working copy |

Presentation helpers live beside it and are pure, so they are tested without libgit2:
`formatStatusLines`, `statusCode`, `formatLogLines`, `relativeDate`, `truncateLines`,
`redactSecrets`, `githubAuthHelp`.

### 6.2 Files — `lib/files/`

- `file_path_rules.dart` — one gate: rejects empty, absolute, backslashed, `..`-containing,
  `.git`-touching and folder-shaped paths. Used by both the UI validator and the write layer,
  so an edited path cannot take a softer route to disk.
- `repo_file_ops.dart` — read, write, exists, delete, rename (with explicit `overwrite`),
  import from device, `looksBinary`. Every repo-relative path passes the gate first and throws
  `ArgumentError` with the reason if it fails.
- `file_tree.dart` — the on-disk tree, `.git` skipped, sorted.

### 6.3 GitHub — `lib/github/`

`listRepos` (paginated), `currentUser` (validation + identity), `checkAccess` (the 403
explainer). `accessVerdictLines` and `parseUserJson` are pure and unit-tested — the access
verdict must be exactly right about *why* a push was refused, which is not something to verify
by pushing to a real repository.

### 6.4 Storage and secrets

| Data | Where | Why |
|---|---|---|
| GitHub PAT | `flutter_secure_storage` (device keystore) | it is a credential |
| Commit identity | `shared_preferences` | not secret, and needed to commit offline |
| Clones | app documents dir, `repos/<owner>/<name>` | nested rather than `owner_name`, which is not injective — `a/b_c` and `a_b/c` would collapse onto one checkout and push to the wrong remote |

---

## 7. Rules the app holds itself to

1. **The token is never rendered.** Every error goes through `redactSecrets` before it can
   reach a widget, and URL-embedded credentials are stripped too.
2. **Destructive actions stop and ask** — delete a file, discard changes, delete a clone,
   overwrite, push. Dismissing a confirm counts as *no*.
3. **Never merge, never guess.** Pull is fast-forward only; divergence is handed back to a real
   git client with an explanation.
4. **Local until pushed.** Every write says it landed in the local clone only.
5. **No silent failure.** One funnel per screen; a refusal is shown in the words it was written
   in, a crash is shown raw with the credential removed.
6. **Untrusted input is validated once, centrally** — path rules run in the same function for
   the UI and the filesystem layer.

---

## 8. Verification

| Check | Result |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | 95 passing |
| `bash android/gradlew -p android assembleDebug` | exit 0 |
| Install + launch on device | `Fully drawn com.jayaarunkumar.pocketgit`, no crash |

Test coverage worth knowing about: real-repo git tests against a local bare remote (selective
staging, branch create/switch, discard, diff, first commit into an empty repo, push retry),
path-escape rejection on every file entry point, GitHub JSON parsing fallbacks, and widget
tests pinning the dialog-controller lifetime that once produced a red screen while adding the
PAT.

---

## 9. Deliberately not built

- **Merge, rebase, conflict resolution** — a phone is the wrong place; pull refuses instead.
- **Background/async git.** libgit2 runs synchronously on the main isolate; a very large clone
  can block the UI. Marked in the source with the upgrade path.
- **Creating an empty file.** The input popup refuses empty text; nobody has asked for one.
- **Multiple accounts, OAuth, SSH keys.** One PAT, one account.
