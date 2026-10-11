# Phase 5 acceptance: launchers

Manual checks for file, folder and command shortcuts on a real Mac. Run them in order on a build of this commit. Every shortcut made here is moved to the Trash at the end; nothing is deleted outright.

## Preconditions

- macOS 26 on Apple silicon, signed in to a normal user account.
- A test folder `~/Desktop/AD Phase 5` containing a folder `Projects`, a text file `notes.txt`, and an executable script `args.sh` with:
  `#!/bin/sh` / `for a in "$@"; do printf '[%s]\n' "$a"; done; echo "HOME=$HOME"; echo "MAD_SHORTCUT_NAME=$MAD_SHORTCUT_NAME"; read -r _`
  (`chmod +x args.sh`).
- TextEdit installed (it is part of macOS). iTerm2 is optional; Step 5 is skipped without it.
- Note the modification time of `~/.zshrc` (or any dotfile in your HOME) before Step 6: `stat -f %m ~/.zshrc`.

## Step 1: Build

- [ ] **1.1** `Tools/build-app.sh --configuration Release` succeeds.
- [ ] **1.2** About App Duplicator shows `Version 0.5.0 (4)`.

## Step 2: Folder shortcut

- [ ] **2.1** New Shortcut → File or Folder → Choose… → `Projects`. The Kind row shows Folder; Next suggests the name `Projects`.
- [ ] **2.2** Create. The shortcut appears under Files and Folders with the subtitle `Projects`.
- [ ] **2.3** Launch it from the Dock: Finder opens `Projects`, and the Dock shows the shortcut's own icon and name while it opens.

## Step 3: File shortcut with an explicit opener

- [ ] **3.1** New Shortcut → File or Folder → Choose… → `notes.txt`; Open with → Choose… → TextEdit. Review shows File, Open with `TextEdit`.
- [ ] **3.2** Create and launch: `notes.txt` opens in TextEdit (not the default app if it differs).
- [ ] **3.3** Edit the shortcut: Open with → Use Default, Save, launch: the file opens in its default app.

## Step 4: Command in Terminal with spaces and quotes

- [ ] **4.1** New Shortcut → Command → Choose… → `args.sh`. Arguments, one per line: `two words`, `"quoted"`, `it's`. Terminal: Terminal.
- [ ] **4.2** Create and launch. macOS asks once to let the shortcut control Terminal; allow it.
- [ ] **4.3** Terminal prints `[two words]`, `["quoted"]`, `[it's]` on three lines, `HOME=` your real HOME, and `MAD_SHORTCUT_NAME=` the shortcut's name (the shortcut's environment is written inline into the new shell, so it must show up here).

## Step 5: Command in iTerm2 (skip without iTerm2)

- [ ] **5.1** Duplicate the Step 4 shortcut, set Terminal to iTerm2, set Working directory to `~/Desktop/AD Phase 5/Projects`, and add a fourth argument line `\(x) it's` (typed exactly: backslash, parentheses, single quote). Save, launch. Allow the Automation prompt.
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
- [ ] **8.3** Rename `notes.txt` in Finder: the Step 3 row shows Item missing in red. Rename it back: the row returns to normal after a rescan.
- [ ] **8.4** Delete the Step 2 shortcut: the sheet shows no data-folder toggle, and `Projects` is untouched.
- [ ] **8.5** Delete the Step 6 shortcut with Also move the command's own HOME folder to the Trash on: the shortcut and `~/Library/Application Support/App Duplicator/<slug>` are both in the Trash.
- [ ] **8.6** Delete the Step 4 shortcut: no HOME toggle is shown, and `args.sh` is untouched.

## Teardown

- Move every remaining Phase 5 shortcut and `~/Desktop/AD Phase 5` to the Trash. Do not empty the Trash as part of this checklist.
- Optionally remove the Automation grants in System Settings → Privacy & Security → Automation.

## Record

| Step | Date | Result | Notes |
|------|------|--------|-------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
| 8 | | | |
