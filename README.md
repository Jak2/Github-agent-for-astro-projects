# PocketGit

A small Android app for the one thing a phone is actually good for in a git
workflow: **see your repositories, write a file, push it.**

No AI, no chat, no agents — every action is a deterministic git operation behind
a button, and every result comes back in a popup.

## What it does

1. **Connect GitHub** — paste a Personal Access Token in Settings. The token is
   validated against the GitHub API before it is stored, and it lives in the
   device keystore (`flutter_secure_storage`), never in shared preferences.
   Commits are authored as the GitHub account the token belongs to.
2. **See your repositories** — every repo the token can reach, searchable, each
   marked cloned or not.
3. **Clone one** — into the app's private storage. Re-clone or delete the local
   clone from the same row.
4. **Handle files** — browse the tree, create a new file at any repo-relative
   path, edit it, rename it, delete it, import one from device storage, discard
   changes. Binary files are refused by the editor rather than corrupted.
5. **Run git** — status, log, diff, branches (switch and create), pull
   (fast-forward only), commit and push (everything, or just the file you were
   working on), and "Check access" when GitHub refuses a push.

## Design rules

- **Popups are the only output surface.** There is no scrollback: a git result,
  a refusal and an error all arrive in the same framed card.
- **The token is never rendered.** Every error message is passed through
  `redactSecrets` before it reaches a widget.
- **Destructive actions stop and ask.** Delete a file, discard changes, delete a
  clone, push — each one confirms first.
- **Fast-forward only, never merge.** `pull` refuses rather than guessing at a
  merge; divergence is a job for a real git client.

## Stack

- Flutter 3.47 / Dart 3.13
- `git2dart` + `git2dart_binaries` — real libgit2 over FFI for clone / commit /
  push / branch / diff
- `dio` — GitHub REST API
- `flutter_secure_storage` — the PAT
- `shared_preferences` — commit identity cache
- `file_picker`, `share_plus`, `path_provider`, `path`, `google_fonts`

## Building & running

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
flutter pub get
flutter run          # or: flutter build apk --debug
```

If the project sits on an NTFS/exFAT mount, `chmod +x` is a no-op there and
Flutter cannot exec `android/gradlew` directly — build with
`bash android/gradlew assembleDebug` instead.

## Token

Generate at github.com/settings/tokens:

- classic token with the **`repo`** scope, or
- fine-grained token with **Contents: Read and write** on the repositories you
  want to push to.

"Check access" in the repo screen tells you which of those is missing when a
push comes back 403.

## History

PocketGit was rebuilt out of an earlier prototype that cloned a repo,
restructured a file with an LLM and pushed the result. All LLM code — engines,
prompts, personas, on-device inference — has been removed; what remains is the
git and file half, promoted to the whole app. The prototype's design documents
are kept under `docs/legacy_prototype/` for the decision history, notably why
`git2dart`, after two other git libraries failed.
