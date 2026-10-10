# Phase 3 acceptance: compatibility profiles

Manual gate. Automated coverage is `Tools/test-app.sh` (MacAppDuplicatorTests) and `swift test --filter CompatProfilesTests`. The steps below need a person at the Mac; Step 10 needs Mike (it launches the real Claude Desktop shortcuts). Tick each box as it passes and fill in the Record table.

## Preconditions

- The Mac is online, and the Phase 3 commits are pushed to `main` on GitHub: the default profiles URL serves `profiles.json` from this repository's `main` branch (Step 6).
- `Claude.app` and `Google Chrome.app` are in `/Applications`; `Claude Work.app` and `Claude Personal.app` are in `~/Applications/App Duplicator` and launch today.
- Default settings: quit App Duplicator and run `defaults delete com.mikekuta.MacAppDuplicator` (an error saying the domain does not exist is fine).
- Bundled profiles only: if `~/Library/Application Support/App Duplicator/profiles.json` exists from an earlier run, move it to the Trash with `mv ~/Library/Application\ Support/App\ Duplicator/profiles.json ~/.Trash/`.
- Run every command from the repository root.

## Step 1: Build

```bash
Tools/build-app.sh --configuration Release
```

- [ ] **1.1** The command prints `<repo>/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app`. Open it with `open "<path>"` (the name contains spaces). Expected: the library window opens and the app menu's About panel shows `Version 0.3.0 (2)`.

## Step 2: Compatibility badges

Press ⌘N, choose `Application`, Next, and read the line under the drop zone (`<App> <version> · <badge>`) as you select each app in turn. Create nothing in this step.

- [ ] **2.1** Select `Claude` in the grid. Expected: `Claude <version> · Verified`.
- [ ] **2.2** Select `Google Chrome`. Expected: `Google Chrome <version> · Auto`. The bundled Chrome profile is `partial` and a partial profile does not change the badge; Chrome shows `Verified` only after the profile is promoted (`docs/acceptance/profile-promotion.md`).
- [ ] **2.3** Click `Browse…`, press ⇧⌘G, go to `/System/Applications/Utilities`, select `Terminal` and click `Open`. Expected: `Terminal <version> · HOME only` (a native app that is not sandboxed; its `partial` profile does not change the badge).
- [ ] **2.4** Select an Electron or Chromium app that has no profile. Obsidian qualifies when `grep -c '"md.obsidian"' Packages/CompatProfiles/Resources/profiles.json` prints `0`; otherwise pick another such app and run the same check with its bundle identifier from `mdls -name kMDItemCFBundleIdentifier "/Applications/<App>.app"`. Expected: `<App> <version> · Auto`. Cancel the wizard.

## Step 3: Wizard prefill and the editor's Profile section

List the bundled profiles that carry arguments or environment variables:

```bash
python3 -I -c '
import json
apps = json.load(open("Packages/CompatProfiles/Resources/profiles.json"))["apps"]
for bid, a in apps.items():
    if a.get("args") or a.get("env"):
        print(bid, a.get("name"), a.get("status"), "args=%s" % json.dumps(a.get("args", [])), "env=%s" % json.dumps(a.get("env", {})), sep="  ")
'
```

Call the first listed app that is installed `<P>`. If the command prints only an empty line, no bundled profile carries arguments or environment: use `Claude` as `<P>` and expect empty Arguments and Environment below.

- [ ] **3.1** ⌘N, `Application`, select `<P>`, Next. Identity: name `Accept Profile`. Data: leave `Auto`. Expected: the note reads `Default: ~/Library/Application Support/App Duplicator/accept-profile`. Next.
- [ ] **3.2** Review. Expected: `Compatibility` shows `<P>`'s badge by the Step 2 rules, and the `Launch plan` disclosure contains the profile's arguments in argv and its environment variables among the additions, exactly as the command printed them. Create.
- [ ] **3.3** In the `Accept Profile` editor, expected: Arguments and Environment hold the profile's values (empty for Claude), and the Profile section shows the match line naming `<P>`'s profile and its status.

## Step 4: Diagnostics

- [ ] **4.1** In the `Accept Profile` editor, type `API_TOKEN` in the empty Environment row's Name field, type `mad-secret-4471` as its value, click ⊕ and Save.
- [ ] **4.2** `Diagnostics…`. Expected: the engine version row reads `1`; the profile rows name the matched profile and its status with every secret-looking value masked; Environment shows `API_TOKEN=••••••`. Click `Copy Report`, then run `pbpaste | grep -c 'mad-secret-4471'`. Expected: `0`. Done.

## Step 5: Data-path guard

In the `Accept Profile` editor, set the data folder to each path below (type it, or use the folder chooser with ⇧⌘G) and Save.

- [ ] **5.1** `~/Documents` (a direct child of your home folder). Expected: Save is refused with an explanation; the stored data folder is unchanged.
- [ ] **5.2** The shortcut's own bundle, `~/Applications/App Duplicator/Accept Profile.app`. Expected: refused the same way.
- [ ] **5.3** The target's own folder, `~/Library/Application Support/<bundle id of P>` (bundle id from the Step 3 command, or `com.anthropic.claudefordesktop` for Claude). Expected: refused the same way.
- [ ] **5.4** Run `mkdir -p ~/Desktop/MAD\ Accept\ Data`, then set the data folder to `~/Desktop/MAD Accept Data` and Save. Expected: accepted; the editor shows the new folder (Step 9 uses it).

## Step 6: Check Profile Updates

- [ ] **6.1** In Settings, copy the profiles URL value somewhere. Expected: an `https://raw.githubusercontent.com/` address on this repository's `main` branch.
- [ ] **6.2** Online, choose Check Profile Updates. Expected: it reports success, and `ls -l ~/Library/Application\ Support/App\ Duplicator/profiles.json` shows a file written just now whose first lines (`head -3` of it) include `"schemaVersion": 1` and an `"updated"` date. Run `shasum -a 256 ~/Library/Application\ Support/App\ Duplicator/profiles.json` and note the hash.
- [ ] **6.3** Turn Wi-Fi off (or unplug the network cable) and choose Check Profile Updates. Expected: an error such as `The Internet connection appears to be offline.`, and the `shasum` command prints the 6.2 hash (the cache is untouched). Turn the network back on.
- [ ] **6.4** Set the profiles URL to `https://example.com/profiles.json` and choose Check Profile Updates. Expected: refused with `https://example.com/profiles.json is not an https://raw.githubusercontent.com address.` (shown when you enter the URL or when you check), and the `shasum` command still prints the 6.2 hash. Paste the 6.1 URL back.

## Step 7: Export into the output folder

- [ ] **7.1** Select `Accept Profile`, `Export…`; in the save panel go to `~/Applications/App Duplicator` (the output folder), name it `Accept Export.app` and Save. Expected: the Export Shortcut sheet shows the library-folder warning and the line saying an existing bundle at the destination is moved to the Trash; `Accept Export` appears in the sidebar. Done.
- [ ] **7.2** Export `Accept Profile` again to the same folder and name, and confirm the save panel's Replace. Expected: the same warning and Trash line; `ls ~/.Trash | grep 'Accept Export'` lists the earlier copy, and `~/Applications/App Duplicator/Accept Export.app` exists. Done.

## Step 8: Rebuild All

- [ ] **8.1** Run `plutil -replace MADEngineVersion -integer 0 ~/Applications/App\ Duplicator/Accept\ Profile.app/Contents/Info.plist`, then choose View → Refresh (⌘R). Expected: `Accept Profile` shows `Needs rebuild` and the toolbar `Rebuild All` enables.
- [ ] **8.2** Click `Rebuild All`. Expected: the sheet opens idle, listing what it will rebuild (including `Accept Profile`), and nothing runs until you start it.
- [ ] **8.3** Start the rebuild. Expected: the sheet shows its running state with progress until every shortcut is done.
- [ ] **8.4** Expected: the sheet shows results, with `Accept Profile` rebuilt successfully. Close it. Expected: the `Needs rebuild` badge is gone and `codesign --verify --deep --strict ~/Applications/App\ Duplicator/Accept\ Profile.app` exits 0 with no output. Note in the Record whether the results listed `Claude Work` and `Claude Personal`.

## Step 9: Delete with data outside the data root

- [ ] **9.1** Select `Accept Profile`, `Delete`. Expected: the sheet offers the data-folder toggle for `~/Desktop/MAD Accept Data`. Turn it on and click Delete. Expected: a second destructive confirmation, because the folder is outside `~/Library/Application Support/App Duplicator`. Confirm. Expected: `Accept Profile.app` and `MAD Accept Data` are in the Trash and the app is still running.

## Step 10: Claude Desktop after Rebuild All (Mike)

- [ ] **10.1** (Mike) `Launch` on `Claude Work`, then on `Claude Personal`. Expected: two Dock icons titled `Claude Work` and `Claude Personal`, both rows show the running dot, and each instance is signed in to its own account (as in Phase 2 Step 6). Quit both.

## Step 11: Known Limitations

- [ ] **11.1** Help → Known Limitations. Expected: 20 entries; the last six are `Compatibility profiles are advisory`, `Partial profiles need manual review`, `Check Profile Updates is manual and fetches from one host`, `Sandboxed native apps cannot be separated`, `Shortcuts whose names match get a numbered slug` and `Export replaces an existing shortcut by moving it to the Trash`.

## Teardown

Move only the test shortcuts to the Trash:

- `~/Applications/App Duplicator/Accept Export.app` (Step 7.2; never launched, so it has no data folder or log)

`Accept Profile.app` and `MAD Accept Data` are already in the Trash (Step 9), and so is the first `Accept Export.app` (Step 7.2). Keep `~/Library/Application Support/App Duplicator/profiles.json`: it is the cache Step 6.2 downloaded. Leave `Claude Work.app` and `Claude Personal.app` in place.

## Record

| Step | Date | Result | Notes |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
| 8 | | | |
| 9 | | | |
| 10 | | | |
| 11 | | | |
