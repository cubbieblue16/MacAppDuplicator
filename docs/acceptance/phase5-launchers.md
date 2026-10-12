# Phase 5 acceptance: launchers

Manual checks for file, folder and command shortcuts on a real Mac. Run them in order on a build of this commit. Every shortcut made here is moved to the Trash at the end; nothing is deleted outright.

## Preconditions

- macOS 26 on Apple silicon, signed in to a normal user account.
- A test folder `~/AD Phase 5` containing a folder `Projects`, a text file `notes.txt`, and an executable script `args.sh` with:
  `#!/bin/sh` / `for a in "$@"; do printf '[%s]\n' "$a"; done; echo "HOME=$HOME"; echo "MAD_SHORTCUT_NAME=$MAD_SHORTCUT_NAME"; read -r _`
  (`chmod +x args.sh`). Keep the folder outside Desktop, Documents and Downloads: a shortcut that opens an item in one of those folders raises a per-shortcut privacy prompt on its first launch, and the item does not open until the prompt is answered by hand.
- TextEdit installed (it is part of macOS). iTerm2 is optional; Step 5 is skipped without it.
- Ghostty is optional; Step 9.3 is skipped without it. Steps 9.1 and 9.2 need a Developer ID Application identity in your keychain (it appears under Settings → Signing → Signing identity); skip them without one.
- Note the modification time of `~/.zshrc` (or any dotfile in your HOME) before Step 6: `stat -f %m ~/.zshrc`.

## Step 1: Build

- [ ] **1.1** `Tools/build-app.sh --configuration Release` succeeds.
- [ ] **1.2** About App Duplicator shows the version and build of the commit under test (`0.7.0 (6)` for the recorded run).

## Step 2: Folder shortcut

- [ ] **2.1** New Shortcut → File or Folder → Choose… → `Projects`. The Kind row shows Folder (the Kind rows select when their label or icon is clicked); Next suggests the name `Projects`.
- [ ] **2.2** Create. The shortcut appears under Files & Folders with the subtitle `Projects`.
- [ ] **2.3** Launch it from the Dock: Finder opens `Projects`, and the Dock shows the shortcut's own icon and name while it opens.

## Step 3: File shortcut with an explicit opener

- [ ] **3.1** New Shortcut → File or Folder → Choose… → `notes.txt`; Open with → Choose… → TextEdit. Review shows File, Open with `TextEdit`.
- [ ] **3.2** Create and launch: `notes.txt` opens in TextEdit (not the default app if it differs).
- [ ] **3.3** Edit the shortcut: Open with → Use Default, Save, launch: the file opens in its default app.

## Step 4: Command in Terminal with spaces and quotes

- [ ] **4.1** New Shortcut → Command → Choose… → `args.sh`. Arguments, one per line: `two words`, `"quoted"`, `it's`. Terminal: Terminal. On 0.7.0 the Arguments editor applies macOS smart-quote substitution while typing, so paste the three lines instead of typing them (0.7.1 turns substitution off in the Arguments and Environment editors; verified on 0.7.1 (7), 2026-10-11: typing `"quoted" it's -- dash` keeps straight quotes and two hyphens).
- [ ] **4.2** Create and launch. macOS asks once to let the shortcut control Terminal; allow it.
- [ ] **4.3** Terminal prints `[two words]`, `["quoted"]`, `[it's]` on three lines, `HOME=` your real HOME, and `MAD_SHORTCUT_NAME=` the shortcut's name (the shortcut's environment is written inline into the new shell, so it must show up here).

## Step 5: Command in iTerm2 (skip without iTerm2)

- [ ] **5.1** Duplicate the Step 4 shortcut, set Terminal to iTerm2, set Working directory to `~/AD Phase 5/Projects`, and add a fourth argument line `\(x) it's` (typed exactly: backslash, parentheses, single quote). Save, launch. Allow the Automation prompt.
- [ ] **5.2** A new iTerm2 window opens with the command echoed at its prompt (`cd '…/Projects' && /usr/bin/env … '…/args.sh' …`), then prints the same three bracketed lines, `[\(x) it's]` exactly as typed, the real HOME and `MAD_SHORTCUT_NAME=` the shortcut's name.
- [ ] **5.3** Press Return to end the script: the window stays open at a shell prompt, and `pwd` there prints the `Projects` folder (the command ran in its working directory).

## Step 6: Background command with its own HOME

- [ ] **6.1** New Shortcut → Command → `args.sh`, no arguments, Terminal: No terminal (run in background). On the Data step turn on Give this command its own HOME; the caption shows `~/Library/Application Support/App Duplicator/<slug>`.
- [ ] **6.2** Create and launch. `~/Library/Application Support/App Duplicator/<slug>` now exists.
- [ ] **6.3** `stat -f %m ~/.zshrc` shows the same time as before: the real HOME is untouched.

## Step 7: Diagnostics

- [ ] **7.1** Diagnostics for the Step 3 shortcut shows Kind File, Item, Open with.
- [ ] **7.2** Diagnostics for the Step 6 shortcut shows Kind Command, Terminal `No terminal (run in background)`, Working directory `Default`, Own HOME with the path, and the command line. Copy Report contains the same lines.
- [ ] **7.3** Add an argument `--token` / `secret123` to a command, Save, open Diagnostics: the command line shows `--token ••••••`, and the copied report does not contain `secret123`.

## Step 8: Duplicate, regenerate, delete

- [ ] **8.1** Duplicate the Step 2 shortcut: the copy has a new name and slug and opens the same folder.
- [ ] **8.2** Regenerate the Step 3 shortcut: it still opens `notes.txt` in its opener; Diagnostics shows the current engine version.
- [ ] **8.3** Move or rename `notes.txt`, then View → Refresh (⌘R): the Step 3 row shows Item missing in red and Launch is disabled. Move it back and refresh: the row returns to normal.
- [ ] **8.4** Delete the Step 2 shortcut: the sheet shows no data-folder toggle, and `Projects` is untouched.
- [ ] **8.5** Delete the Step 6 shortcut with Also move the command's own HOME folder to the Trash on: the shortcut and `~/Library/Application Support/App Duplicator/<slug>` are both in the Trash.
- [ ] **8.6** Delete the Step 4 shortcut: no HOME toggle is shown, and `args.sh` is untouched.

## Step 9: Automation permission and Ghostty (Mike-present)

- [ ] **9.1** Settings → Signing → Signing identity: choose your Developer ID identity. New Shortcut → Command → `args.sh`, no arguments, Terminal: Terminal. Create and launch. macOS asks once to let the shortcut control Terminal, explaining "<Name> opens your terminal to run its command."; allow it. Terminal opens and runs the command; press Return to end it. Launch again: Terminal runs the command with no second prompt.
- [ ] **9.2** Turn the 9.1 shortcut off for Terminal in System Settings → Privacy & Security → Automation (or run `tccutil reset AppleEvents <bundle id>`, launch, and choose Don't Allow), then launch it. No Terminal window opens. The "Shortcut could not start" alert says the terminal could not be opened, quotes the Not authorized to send Apple events error, and names the fix: System Settings > Privacy & Security > Automation, or `tccutil reset AppleEvents` followed by this shortcut's bundle id. Settings → General → Open Logs Folder: the shortcut's log ends with an `error …` line and `exit 3`. Turn the permission back on (or run the `tccutil` line from the alert and allow the prompt on the next launch).
- [ ] **9.3** (skip without Ghostty) New Shortcut → Command → `args.sh`, one argument line `two words`, Terminal: Ghostty. Create and launch. A new Ghostty window opens and prints `[two words]` and `HOME=` your real HOME (`MAD_SHORTCUT_NAME` can be empty here: Ghostty commands start in Ghostty's own environment). Press Return to end the script.

## Teardown

- Move every remaining Phase 5 shortcut and `~/AD Phase 5` to the Trash. Do not empty the Trash as part of this checklist.
- Optionally remove the Automation grants in System Settings → Privacy & Security → Automation.

## Record

| Step | Date | Result | Notes |
|------|------|--------|-------|
| 1 | 2026-10-11 | N/A | Installed 0.7.0 (6) used; build step covered by Phase 7 |
| 2 | 2026-10-11 | PASS | 2.1–2.3 folder shortcut created, Finder opened `Projects`; fixtures moved off `~/Desktop` after the first launch hit the per-shortcut Desktop privacy prompt (doc updated) |
| 3 | 2026-10-11 | PASS | 3.1–3.3 file shortcut with TextEdit opener, then Use Default; launcher log shows `kind file`, `open`, `opener` lines |
| 4 | 2026-10-11 | PASS (4.1) / BUG | 4.1 created; the Arguments editor applied smart quotes while typing (`“quoted”`, `it’s`), pasted lines stored correctly. Fix ships in 0.7.1. 4.2–4.3 need the Automation prompt (Mike-present) |
| 5 | 2026-10-11 | N/A | iTerm2 not installed |
| 6 | 2026-10-11 | PASS | 6.1–6.3 background command with own HOME; `~/Library/Application Support/App Duplicator/args-bg` created, `~/.zshrc` mtime unchanged |
| 7 | 2026-10-11 | PASS | 7.1–7.3 Diagnostics for file and command shortcuts; `--token` value masked as `••••••` and absent from the copied report |
| 8 | 2026-10-11 | PASS | 8.1–8.6 duplicate, regenerate, missing-item state, delete without toggle (file shortcut), delete with the own-HOME toggle (shortcut and HOME tree in the Trash), delete of a command without own HOME shows no toggle. Nit: Return in the Delete alert does nothing (no default button). Fixed in 0.7.1 (7), verified 2026-10-11: Return cancels, Escape dismisses, the web-data question keeps `Keep Web Data` as its default |
| 9 | 2026-10-11 | PENDING | Mike-present (Automation permission, Ghostty) |
| 4.1 re-check | 2026-10-11 | PASS (0.7.1) | 0.7.1 (7): Arguments editor keeps `"quoted" it's -- dash` verbatim when typed (app-domain `NSAutomaticQuoteSubstitutionEnabled`/`Dash`/`TextReplacement` = 0; global still 1) |
