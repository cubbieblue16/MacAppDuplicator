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
- Folder-access prompts: when `$OUT` or a custom data folder sits under Desktop, Documents or Downloads, macOS shows a per-shortcut "wants to access files in your Desktop folder" prompt (or the Documents or Downloads equivalent) the first time the launcher reads that folder. Each shortcut has its own bundle id, so each gets its own prompt, and the launcher writes nothing to its log after the `start` line until the prompt is answered. App Duplicator itself gets the same prompt on first export there. Answer the prompts as they appear, or, when running unattended, create `$OUT` outside those folders: `OUT=$(mktemp -d "$HOME/Library/Caches/ad-phase6.XXXXXX")`.

## Step 1: Build

- [ ] **1.1** Build the three products one at a time (`swift build` takes one `--product` per run): `swift build -c release --product Launcher 2>&1 | tail -1`, then `swift build -c release --product WebShell 2>&1 | tail -1`, then `swift build -c release --product madctl 2>&1 | tail -1`; each prints `Build complete!`.
- [ ] **1.2** `Tools/build-app.sh --configuration Release` succeeds.
- [ ] **1.3** About App Duplicator shows `Version 0.7.0 (6)`.
- [ ] **1.4** `Tools/build-fixture.sh` succeeds and `ls .build/fixtures/FixtureApp.app/Contents/Resources` lists `AppIcon.icns`.
- [ ] **1.5** `MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | grep -E "Executed [0-9]+ tests?"` prints several lines; one of them reads `Executed 5 tests, with 0 failures (0 unexpected) in …` (the `IntegrationTests` bundle; the trailing `Executed 0 tests` lines belong to the other bundles). Do not start Step 4 if it fails: this run includes the erase-on-quit test on a throwaway folder.
- [ ] **1.6** Create the two fixture shortcuts: `.build/release/madctl new .build/fixtures/FixtureApp.app --name "AD P6 Fixture" --env MAD_FIXTURE_LIFETIME=600 --out "$OUT"` and `.build/release/madctl new .build/fixtures/FixtureApp.app --name "AD P6 Erase" --data-mode home --env MAD_FIXTURE_LIFETIME=5 --out "$OUT"`. Both succeed and `ls "$OUT"` lists `AD P6 Erase.app` and `AD P6 Fixture.app`.
- [ ] **1.7** Settings → General → Output folder → `Browse…`, press ⇧⌘G, paste the folder `echo "$OUT"` printed and choose it. The sidebar lists exactly `AD P6 Erase` and `AD P6 Fixture` under Apps (press ⌘R to refresh if they are missing).

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
- [ ] **5.4** Choose `Quit AD P6 TextEdit` from its menu bar icon. Run `open -a TextEdit`: its menus use your system language. Quit it with ⌘Q. On macOS 27 with a menu bar manager such as Ice running, the icon may not be drawn (see the Known Limitation "The menu bar icon may not be drawn on macOS 27 with a menu bar manager running"); quit the shortcut from Activity Monitor instead, or run `kill -TERM <pid>` with the pid from `pgrep -f 'AD P6 TextEdit.app/Contents/MacOS'`.
- [ ] **5.5** Clear `Language` and press `Save`: `Diagnostics…` shows `Language: System`. Press `Launch`: the menus use your system language. Quit it from its menu bar icon (or, if the icon is not drawn as described in 5.4, from Activity Monitor or with `kill -TERM <pid>` using the pid from `pgrep -f 'AD P6 TextEdit.app/Contents/MacOS'`).

## Step 6: Diagnostics

- [ ] **6.1** Select `AD P6 Fixture` and open `Diagnostics…`: the rows read `Menu bar icon: On`, `Erase on quit: Off`, `New Window command: /usr/bin/env open -na <fixture path>` and `Language: System`.
- [ ] **6.2** Press `Copy Report`, then run `pbpaste | grep -E '^(Menu bar icon|Erase on quit|New Window command|Language): '`: it prints those four lines.
- [ ] **6.3** Select `AD P6 Erase` and open `Diagnostics…`: `Erase on quit: On: ` followed by the `custom-data` path. This assumes 4.8 saved the custom data folder; if 4.8 was skipped, the row shows the default `ad-p6-erase` path instead.

## Teardown

- Quit every shortcut from this checklist; `pgrep -lf 'AD P6'` prints nothing.
- Settings → General → Output folder → `Browse…`: restore the folder written down in Preconditions; your own shortcuts reappear in the sidebar.
- In Finder, move to the Trash: the `$OUT` folder, `/Users/Shared/ad-p6-outside`, the folders `ad-p6-erase`, `ad-p6-fixture` and `ad-p6-textedit` in `~/Library/Application Support/App Duplicator/` (those that exist), and `AD P6 Erase.log`, `AD P6 Fixture.log` and `AD P6 TextEdit.log` in `~/Library/Logs/App Duplicator/`. Do not empty the Trash as part of this checklist.

## Record

| Step | Date | Result | Notes |
|---|---|---|---|
| 1.1-1.7 | 2026-10-11 | PASS | Builds, fixtures and integration (5 integration tests pass at d6ccfb0); `AD P6 Fixture` (lifetime 600) and `AD P6 Erase` (home, lifetime 5) created in `$OUT`, both `codesign --verify --deep --strict` ok; Settings → Output folder → `Browse…` lists exactly `AD P6 Erase` and `AD P6 Fixture`. Doc nits: 1.3 said `0.6.0 (5)` (installed is `0.7.0 (6)`), `Choose…` is `Browse…`. |
| 2.1 | 2026-10-11 | PASS | `MAD Fixture` window opens, no menu bar icon, no `--helper` process, log ends `exec`, data folder `ad-p6-fixture` created. Quit via `kill -TERM` (Dock tile not reachable in captures). |
| 2.2 | 2026-10-11 | PASS | Notes read "New Window is hidden until you enter a command." and "New Window appears only while Menu bar icon is on."; config verified with plutil. |
| 2.3 | 2026-10-11 | PARTIAL | Helper spawned and logged (`helper spawned`, `helper start … data=-`, `helper exec observed`); pgrep line ends `AD P6 Fixture.app -`. Status item NOT drawn: MenuBarAgent logs `Creating status item … isAllowed: true` then `No server elements for status item: nil`. A minimal standalone NSStatusItem probe shows the same, so it is environmental (macOS 27 MenuBarAgent with Ice 27.0); see the Known Limitation. |
| 2.4 | 2026-10-11 | BLOCKED (env) | Status-item menu not drawn, so `Show` could not be clicked. Reopen path (same `show()`) covered by 2.6: fixture came to front, no `helper show failed` line. |
| 2.5 | 2026-10-11 | BLOCKED (env) | `New Window` unreachable (status item not drawn). Command wiring checked in Diagnostics. |
| 2.6 | 2026-10-11 | PASS | `open` of the bundle: `pgrep -x FixtureApp | wc -l` printed 1 (option a), helper count stayed 1, no new log lines. |
| 2.7 | 2026-10-11 | BLOCKED (env) | `Quit` unreachable. `kill -TERM` on the helper exited it silently and left the target running (the Quit path is the menu action, which signals the target). A lifetime-expiry run showed `helper target exited status=0` / `helper exit` with no `helper erase`. |
| 2.8 | 2026-10-11 | PASS | Icon off + Save: Diagnostics `Menu bar icon: Off` and `New Window command: … (hidden: the menu bar icon is off)`; Launch runs with no `--helper` process and no `helper spawned` log line. |
| 3.1 | 2026-10-11 | PASS | `AD P6 TextEdit` created from `/System/Applications/TextEdit.app`; Launch mode greyed at System Launch with the Apple-platform-binary caption. Nit: wizard step 2 caption reads "TextEdit 1.21 · Unknown". |
| 3.2 | 2026-10-11 | PASS | Menu bar icon on and `open -na {target}` saved; MADConfig menuBarIcon=true, newWindowCommand set. |
| 3.3 | 2026-10-11 | PARTIAL | One shortcut process, no `--helper`; `pgrep -x TextEdit` = 1 (baseline 0); log `helper start pid=73777 watch=73791 … data=-`. Menu bar icon NOT drawn (MenuBarAgent `running-active-NotVisible`, same macOS 27 limit as 2.3). |
| 3.4 | 2026-10-11 | BLOCKED (env) | No status-item menu to choose `Show`; reopen path covered by 3.5. |
| 3.5 | 2026-10-11 | PASS | Reopen: TextEdit count still 1, shortcut process still one line. |
| 3.6 | 2026-10-11 | BLOCKED (env) | No status-item menu for `New Window`. |
| 3.7 | 2026-10-11 | BLOCKED (env) | No menu `Quit`. Target-exit path exercised: SIGTERM to TextEdit → `helper target exited status=143`, `helper exit`; no `helper spawned` or `helper exec observed` lines. |
| 4.1 | 2026-10-11 | PASS | `ls -la "$DATA"` shows symlinks including Desktop, Documents and .ssh, a real Library, and the `.mad-home-tree` marker. |
| 4.2 | 2026-10-11 | PASS | Baselines: Desktop 17, Documents 35, .ssh 8, `$OUT` = 3 apps. |
| 4.3 | 2026-10-11 | PASS | Erase on quit turns on with no confirmation; Diagnostics `Erase on quit: On: /Users/cubbieblue16/Library/Application Support/App Duplicator/ad-p6-erase`. |
| 4.4 | 2026-10-11 | PASS | After quit `ls -A "$DATA"` is empty, `kept`, no processes; log `helper exec observed` / `helper target exited status=0` / `helper erase … removed=18` / `helper exit`. |
| 4.5 | 2026-10-11 | PASS | Baselines unchanged (17/35/8); symlinks removed without following. |
| 4.6 | 2026-10-11 | PASS | `helper erase skipped: another copy of this shortcut is still running (pid 74521)` then `helper erase … removed=17`; folder empty. |
| 4.7 | 2026-10-11 | PASS | Sheet "Erase this folder on quit?" matches the doc; Cancel keeps the default data folder and the toggle on. |
| 4.8 | 2026-10-11 | BLOCKED (TCC) | custom-data + Erase on Quit saved, but the launcher blocked in open() on the Desktop folder (per-shortcut Desktop folder-access prompt, answered only by Mike); SIGTERMed, marker.txt kept. A later misclick restored the default dataPath; erase stays on. |
| 4.9 | 2026-10-11 | PASS | Toggle off, then on shows the confirmation; Cancel leaves the toggle off. |
| 4.10 | 2026-10-11 | PASS | `/Users/Shared/ad-p6-outside/data`: no confirmation, toggle off, red caption "Erase on quit never empties this folder: the folder is outside the home folder."; Revert restores the default path and toggle. |
| 4.11 | 2026-10-11 | PASS | Data Disabled: toggle off and dimmed, caption "Erase on quit needs a data folder: set Data to Auto or HOME override."; Revert restores HOME override. |
| 4.12 | 2026-10-11 | PASS | `madctl plan … --data-mode disabled --erase-on-quit` prints `Error: --erase-on-quit needs --data-mode auto or home` (exit 64). |
| 5.1 | 2026-10-11 | PASS | `en_US` shows red "Use a language code like en, fr or pt-BR." and Save is disabled. |
| 5.2 | 2026-10-11 | PASS | `fr` + Save: plist `languageCode = fr`; Diagnostics `Language: fr`, Arguments `-AppleLanguages (fr) -AppleLocale fr`. |
| 5.3 | 2026-10-11 | PASS | TextEdit argv `-AppleLanguages (fr) -AppleLocale fr`; menu bar `Fichier Édition Format Présentation Fenêtre Aide`. |
| 5.4 | 2026-10-11 | PARTIAL (env) | Icon not drawn (macOS 27 with Ice), so quit via SIGTERM to the helper and TextEdit; `open -a TextEdit` then started with plain argv (no -AppleLanguages). Menus not eyeballed. |
| 5.5 | 2026-10-11 | NOT RUN | Usage limit reached. |
| 6 | 2026-10-11 | NOT RUN | Usage limit reached; 6.1 to 6.3 not exercised. |
