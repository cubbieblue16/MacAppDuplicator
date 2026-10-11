# Phase 6 acceptance: helper

Manual checks for the helper on a real Mac, with Mike present: the menu bar icon (Show, New Window, Quit) on a Dock Shortcut and on a System Launch shortcut, erase on quit, and the language override. Run them in order on a build of this commit. Every shortcut made here lives in a fresh temporary output folder, every folder that gets erased is a test folder, and everything is moved to the Trash at the end; nothing is deleted outright.

## Preconditions

- macOS 26 on Apple silicon, signed in to a normal user account.
- A current backup (Time Machine or similar). Step 4 empties real folders under your home folder; the guards limit it to the test folders, and Step 4 is what proves that.
- TextEdit installed (it is part of macOS) and not running: `pgrep -x TextEdit` prints nothing.
- Write down the current output folder (Settings → General → Output folder) so Teardown can restore it.
- In Terminal, from the repository (keep this window open; later steps use `$OUT`, `$LOGS` and `$DATA`):
  `cd ~/Developer/MacAppDuplicator`
  `OUT=$(mktemp -d "$HOME/Desktop/ad-phase6.XXXXXX") && echo "$OUT"`
  `LOGS="$HOME/Library/Logs/App Duplicator"`
  `DATA="$HOME/Library/Application Support/App Duplicator/ad-p6-erase"`

## Step 1: Build

- [ ] **1.1** Build the three products one at a time (`swift build` takes one `--product` per run): `swift build -c release --product Launcher 2>&1 | tail -1`, then `swift build -c release --product WebShell 2>&1 | tail -1`, then `swift build -c release --product madctl 2>&1 | tail -1`; each prints `Build complete!`.
- [ ] **1.2** `Tools/build-app.sh --configuration Release` succeeds.
- [ ] **1.3** About App Duplicator shows `Version 0.6.0 (5)`.
- [ ] **1.4** `Tools/build-fixture.sh` succeeds and `ls .build/fixtures/FixtureApp.app/Contents/Resources` lists `AppIcon.icns`.
- [ ] **1.5** `MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | grep -E "Executed [0-9]+ tests?"` prints several lines; one of them reads `Executed 5 tests, with 0 failures (0 unexpected) in …` (the `IntegrationTests` bundle; the trailing `Executed 0 tests` lines belong to the other bundles). Do not start Step 4 if it fails: this run includes the erase-on-quit test on a throwaway folder.
- [ ] **1.6** Create the two fixture shortcuts: `.build/release/madctl new .build/fixtures/FixtureApp.app --name "AD P6 Fixture" --env MAD_FIXTURE_LIFETIME=600 --out "$OUT"` and `.build/release/madctl new .build/fixtures/FixtureApp.app --name "AD P6 Erase" --data-mode home --env MAD_FIXTURE_LIFETIME=5 --out "$OUT"`. Both succeed and `ls "$OUT"` lists `AD P6 Erase.app` and `AD P6 Fixture.app`.
- [ ] **1.7** Settings → General → Output folder → `Choose…`, press ⇧⌘G, paste the folder `echo "$OUT"` printed and choose it. The sidebar lists exactly `AD P6 Erase` and `AD P6 Fixture` under Apps (press ⌘R to refresh if they are missing).

## Step 2: Menu bar icon on a Dock Shortcut

- [ ] **2.1** Select `AD P6 Fixture` and press `Launch`. The `MAD Fixture` window opens, no menu bar icon appears, and `pgrep -lf 'AD P6 Fixture.*--helper'` prints nothing (no helper while the menu bar icon and erase on quit are off). Quit it: Control-click its Dock tile → Quit (the fixture has no menus, so ⌘Q does nothing).
- [ ] **2.2** In the editor's Advanced section turn `Menu bar icon` on: the note under `New Window command` reads "New Window is hidden until you enter a command." Type `open -na {target}` into `New Window command`: the note goes away. Turn `Menu bar icon` off: the note reads "New Window appears only while Menu bar icon is on." Turn it on again and press `Save`.
- [ ] **2.3** Press `Launch`. Within a few seconds the fixture's icon appears in the menu bar in full colour (not a grey silhouette); its menu reads `Show AD P6 Fixture`, `New Window`, a separator, `Quit AD P6 Fixture`. The sidebar row shows it running. `pgrep -lf 'AD P6 Fixture.*--helper'` prints exactly one line, and that line ends with `AD P6 Fixture.app -` (the `-` means no folder to erase).
- [ ] **2.4** Click another app's window, then choose `Show AD P6 Fixture`: the `MAD Fixture` window comes to the front. If it does not, the step fails; record what `tail -n 5 "$LOGS/AD P6 Fixture.log"` shows (`helper show failed: macOS refused to activate pid …` means macOS declined the activation).
- [ ] **2.5** Choose `New Window`: a second `MAD Fixture` window opens (a second fixture process) and closes by itself after about 3 seconds, because `open` starts it through LaunchServices without the shortcut's `MAD_FIXTURE_LIFETIME`. `grep 'helper new window' "$LOGS/AD P6 Fixture.log" | tail -n 1` shows `helper new window argv /usr/bin/env open -na ` followed by the fixture's absolute path, ending in `.build/fixtures/FixtureApp.app`.
- [ ] **2.6** Run `open "$OUT/AD P6 Fixture.app"; sleep 5; pgrep -x FixtureApp | wc -l` and record which of these happened; either passes: (a) it prints `1` and the existing `MAD Fixture` window came to the front; (b) it prints `2` and a second copy with its own menu bar icon started (quit that copy with its own `Quit AD P6 Fixture` before going on).
- [ ] **2.7** Choose `Quit AD P6 Fixture`. Within 10 seconds the window closes, the menu bar icon goes away, the sidebar row stops showing it running, and `pgrep -lf 'AD P6 Fixture'` prints nothing. `grep helper "$LOGS/AD P6 Fixture.log" | tail -n 20` contains, in this order: `helper spawned pid=…`, `helper start pid=… watch=… bundle=… data=-`, `helper exec observed`, `helper new window argv …`, `helper quit signal=15`, `helper target exited status=143` (or `status=unavailable`), `helper exit`; there is no `helper erase` line.
- [ ] **2.8** Turn `Menu bar icon` off and press `Save`. `Diagnostics…` shows `Menu bar icon: Off` and `New Window command: /usr/bin/env open -na <fixture path> (hidden: the menu bar icon is off)`. Press `Launch`: no menu bar icon appears and `pgrep -lf 'AD P6 Fixture.*--helper'` prints nothing. Quit it from its Dock tile, then turn `Menu bar icon` back on and press `Save`.

## Step 3: Menu bar icon with System Launch (TextEdit)

- [ ] **3.1** ⌘N → `Application` → `Browse…` → `/System/Applications/TextEdit.app` → `Next`; name it `AD P6 TextEdit` and press `Create`. In its editor, `Launch mode` is `System Launch` (TextEdit is a platform binary, so Dock Shortcut is not available).
- [ ] **3.2** In Advanced turn `Menu bar icon` on, enter `open -na {target}` as the `New Window command` and press `Save`.
- [ ] **3.3** Press `Launch`. TextEdit starts with its own Dock tile and no `AD P6 TextEdit` Dock tile stays; the TextEdit icon appears in the menu bar in full colour, with `Show AD P6 TextEdit`, `New Window`, a separator and `Quit AD P6 TextEdit`. `pgrep -lf 'AD P6 TextEdit.app/Contents/MacOS'` prints exactly one line, and that line has no `--helper` (with System Launch the shortcut itself stays open as the helper).
- [ ] **3.4** Click another app's window, then choose `Show AD P6 TextEdit`: TextEdit comes to the front.
- [ ] **3.5** Run `open "$OUT/AD P6 TextEdit.app"; sleep 3; pgrep -x TextEdit | wc -l`: TextEdit comes to the front, the command prints `1`, and `pgrep -lf 'AD P6 TextEdit.app/Contents/MacOS'` still prints one line.
- [ ] **3.6** Choose `New Window`: a second TextEdit starts (`pgrep -x TextEdit | wc -l` prints `2`), and `grep 'helper new window' "$LOGS/AD P6 TextEdit.log" | tail -n 1` shows `helper new window argv /usr/bin/env open -na /System/Applications/TextEdit.app`.
- [ ] **3.7** Choose `Quit AD P6 TextEdit`. Within 10 seconds `pgrep -x TextEdit | wc -l` prints `1` (the copy the shortcut started is gone; the New Window copy stays), no save prompt appears, the menu bar icon goes away and `pgrep -lf 'AD P6 TextEdit.app/Contents/MacOS'` prints nothing. Quit works like `kill`: an unsaved document in the quit copy would be lost without a prompt. `grep helper "$LOGS/AD P6 TextEdit.log"` contains, in this order: `helper start pid=… watch=… bundle=… data=-`, `helper new window argv …`, `helper quit signal=15`, `helper target exited status=…` (a number or `unavailable`), `helper exit`; it has no `helper spawned` and no `helper exec observed` line. Quit the remaining TextEdit with ⌘Q.

## Step 4: Erase on quit

- [ ] **4.1** Select `AD P6 Erase`, press `Launch` and let the fixture quit by itself (about 5 seconds). `ls -la "$DATA"` lists symbolic links into your home folder, among them `Desktop -> /Users/<you>/Desktop` and `Documents -> /Users/<you>/Documents`.
- [ ] **4.2** Record these baselines: `ls -A "$HOME/Desktop" | wc -l`, `ls -A "$HOME/Documents" | wc -l`, `ls -A "$HOME/.ssh" 2>/dev/null | wc -l` and `ls "$OUT"`.
- [ ] **4.3** In the editor's Launch section turn `Erase on quit` on: it turns on at once, with no question (the folder is inside App Duplicator's data folder). Press `Save`. `Diagnostics…` shows `Erase on quit: On: /Users/<you>/Library/Application Support/App Duplicator/ad-p6-erase`.
- [ ] **4.4** Run `touch "$DATA/marker.txt"`, press `Launch` and wait for the fixture to quit. Then `ls -A "$DATA"` prints nothing, `test -d "$DATA" && echo kept` prints `kept`, `pgrep -lf 'AD P6 Erase'` prints nothing, and `grep helper "$LOGS/AD P6 Erase.log" | tail -n 4` shows `helper exec observed`, `helper target exited status=0` (or `status=unavailable`), `helper erase /Users/<you>/Library/Application Support/App Duplicator/ad-p6-erase removed=<n>` and `helper exit`.
- [ ] **4.5** Run the four baseline commands from 4.2 again: every count and the `ls "$OUT"` listing are unchanged. The erase removed the links into your home folder without following them.
- [ ] **4.6** Run `open -n "$OUT/AD P6 Erase.app"; sleep 2; open -n "$OUT/AD P6 Erase.app"` and wait about 10 seconds for both copies to quit. `grep 'helper erase' "$LOGS/AD P6 Erase.log" | tail -n 2` shows `helper erase skipped: another copy of this shortcut is still running (pid <n>)` followed by `helper erase … removed=<n>`, and `ls -A "$DATA"` prints nothing.
- [ ] **4.7** Run `mkdir "$OUT/custom-data"`. With `Erase on quit` still on, press the data folder's `Browse…`, press ⇧⌘G, paste the `custom-data` path and choose it. A confirmation appears: the title "Erase this folder on quit?", a message that starts "Every time AD P6 Erase quits, everything inside", names the `custom-data` folder, says everything inside it is deleted permanently and not moved to the Trash, and ends "This folder is outside App Duplicator's data folder.", and the buttons `Erase on Quit` and `Cancel`. Press `Cancel`: `Data folder` still shows the default folder and `Erase on quit` stays on.
- [ ] **4.8** Choose the `custom-data` folder again and press `Erase on Quit`: `Data folder` shows the `custom-data` path. Press `Save`. Run `touch "$OUT/custom-data/marker.txt"`, press `Launch` and wait for the fixture to quit: `ls -A "$OUT/custom-data"` prints nothing, `test -d "$OUT/custom-data" && echo kept` prints `kept`, and `ls "$OUT"` still lists `AD P6 Erase.app`, `AD P6 Fixture.app`, `AD P6 TextEdit.app` and `custom-data` (the data folder's `Desktop` link pointed at the folder that holds `$OUT`; it was removed, not followed).
- [ ] **4.9** Turn `Erase on quit` off, then on again: the confirmation appears. Press `Cancel`: the toggle stays off.
- [ ] **4.10** Press `Revert` (the saved state: `custom-data`, Erase on quit on). Run `mkdir -p /Users/Shared/ad-p6-outside/data`, then choose that folder with the data folder's `Browse…` (⇧⌘G): no confirmation appears, `Data folder` shows `/Users/Shared/ad-p6-outside/data`, `Erase on quit` turns off, and a red message reads "Erase on quit never empties this folder: the folder is outside the home folder." Turn `Erase on quit` on: it stays off and the same message shows. Press `Revert`.
- [ ] **4.11** Set `Data` to `Disabled`: `Erase on quit` turns off and is dimmed, and the caption reads "Erase on quit needs a data folder: set Data to Auto or HOME override." Press `Revert`.
- [ ] **4.12** `.build/release/madctl plan .build/fixtures/FixtureApp.app --data-mode disabled --erase-on-quit 2>&1 | grep -m1 'Error:'` prints `Error: --erase-on-quit needs --data-mode auto or home`.

## Step 5: Language override (TextEdit fr)

- [ ] **5.1** Select `AD P6 TextEdit`. In the Launch section type `en_US` into `Language`: a red message reads "Use a language code like en, fr or pt-BR." and `Save` is disabled.
- [ ] **5.2** Change it to `fr` and press `Save`. `Diagnostics…` shows `Language: fr`.
- [ ] **5.3** With no TextEdit running (`pgrep -x TextEdit` prints nothing), press `Launch`: TextEdit's menus are in French (`Fichier`, `Édition`, `Format`).
- [ ] **5.4** Choose `Quit AD P6 TextEdit` from its menu bar icon. Run `open -a TextEdit`: its menus use your system language. Quit it with ⌘Q.
- [ ] **5.5** Clear `Language` and press `Save`: `Diagnostics…` shows `Language: System`. Press `Launch`: the menus use your system language. Quit it from its menu bar icon.

## Step 6: Diagnostics

- [ ] **6.1** Select `AD P6 Fixture` and open `Diagnostics…`: the rows read `Menu bar icon: On`, `Erase on quit: Off`, `New Window command: /usr/bin/env open -na <fixture path>` and `Language: System`.
- [ ] **6.2** Press `Copy Report`, then run `pbpaste | grep -E '^(Menu bar icon|Erase on quit|New Window command|Language): '`: it prints those four lines.
- [ ] **6.3** Select `AD P6 Erase` and open `Diagnostics…`: `Erase on quit: On: ` followed by the `custom-data` path.

## Teardown

- Quit every shortcut from this checklist; `pgrep -lf 'AD P6'` prints nothing.
- Settings → General → Output folder → `Choose…`: restore the folder written down in Preconditions; your own shortcuts reappear in the sidebar.
- In Finder, move to the Trash: the `$OUT` folder, `/Users/Shared/ad-p6-outside`, the folders `ad-p6-erase`, `ad-p6-fixture` and `ad-p6-textedit` in `~/Library/Application Support/App Duplicator/` (those that exist), and `AD P6 Erase.log`, `AD P6 Fixture.log` and `AD P6 TextEdit.log` in `~/Library/Logs/App Duplicator/`. Do not empty the Trash as part of this checklist.

## Record

| Step | Date | Result | Notes |
|------|------|--------|-------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
