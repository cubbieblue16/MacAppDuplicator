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
- [ ] **5.3** The target's own data folder in `~/Library/Application Support`: a folder named after the app or its bundle identifier (for Claude it is `~/Library/Application Support/Claude`; `ls ~/Library/Application\ Support | grep -i <app name>` finds it). Expected: refused the same way.
- [ ] **5.4** Run `mkdir -p ~/Desktop/MAD\ Accept\ Data`, then set the data folder to `~/Desktop/MAD Accept Data` and Save. Expected: accepted; the editor shows the new folder (Step 9 uses it).

## Step 6: Check Profile Updates

- [ ] **6.1** In Settings, copy the profiles URL value somewhere. Expected: an `https://raw.githubusercontent.com/` address on this repository's `main` branch.
- [ ] **6.2** Online, choose Check Profile Updates. Expected: it reports success. The cache is written only when the downloaded catalog's `updated` date is newer than the bundled one: in that case `ls -l ~/Library/Application\ Support/App\ Duplicator/profiles.json` shows a file written just now whose first lines (`head -3` of it) include `"schemaVersion": 1` and an `"updated"` date; run `shasum -a 256` on it and note the hash. When the dates are equal (as on 2026-10-11, both `2026-10-10`) no cache file exists afterwards, and that is expected; the `shasum` checks in 6.3 and 6.4 then verify that the file still does not exist.
- [ ] **6.3** Turn Wi-Fi off (or unplug the network cable) and choose Check Profile Updates. Expected: an error such as `The Internet connection appears to be offline.`, and the `shasum` command prints the 6.2 hash (the cache is untouched). Turn the network back on.
- [ ] **6.4** Set the profiles URL to `https://example.com/profiles.json` and choose Check Profile Updates. Expected: as soon as the URL is entered the Settings pane shows `Use an https://raw.githubusercontent.com address.` and the Check Now button is disabled, so no check runs and the `shasum` command still prints the 6.2 hash (or the file still does not exist). Use `Reset to Default` to restore the 6.1 URL; it also removes the `profilesURLString` defaults key.

## Step 7: Export into the output folder

- [ ] **7.1** Select `Accept Profile`, `Export…`; in the save panel go to `~/Applications/App Duplicator` (the output folder), name it `Accept Export.app` and Save. Expected: an alert `Export into a library folder?` warns that the copy would appear as a second shortcut with the same bundle identifier and data folder; choose Export Anyway. The Export Shortcut sheet then shows the signing identity and the quarantine command (no Trash line yet, because nothing was replaced). The copy appears in the sidebar labelled `Accept Profile` (the label comes from the stored shortcut name, not the file name), with the same slug. Done.
- [ ] **7.2** Export `Accept Profile` again to the same folder and name, and confirm the save panel's Replace. Expected: the same library-folder alert, then the Export Shortcut sheet now also shows the Trash line (`The item that was at … is in the Trash: ~/.Trash/Accept Export.app`); `ls ~/.Trash | grep 'Accept Export'` lists the earlier copy (renamed with a timestamp suffix if the name was taken), and `~/Applications/App Duplicator/Accept Export.app` exists. Done.

## Step 8: Rebuild All

- [ ] **8.1** Run `plutil -replace MADEngineVersion -integer 0 ~/Applications/App\ Duplicator/Accept\ Profile.app/Contents/Info.plist`, then choose View → Refresh (⌘R). Expected: `Accept Profile` shows `Needs rebuild` and the toolbar `Rebuild All` enables.
- [ ] **8.2** Click `Rebuild All`. Expected: the sheet opens idle as `Rebuild 1 shortcut?` (it shows the count of stale shortcuts, not their names) with `Each shortcut is rewritten with the current launcher and signed again. Settings are kept.`, and nothing runs until you start it.
- [ ] **8.3** Start the rebuild. Expected: the sheet shows its running state with progress until every shortcut is done.
- [ ] **8.4** Expected: the sheet shows results, with `Accept Profile` rebuilt successfully. Close it. Expected: the `Needs rebuild` badge is gone and `codesign --verify --deep --strict ~/Applications/App\ Duplicator/Accept\ Profile.app` exits 0 with no output. Note in the Record whether the results listed `Claude Work` and `Claude Personal`.

## Step 9: Delete with data outside the data root

- [ ] **9.0** First move the Step 7 copy to the Trash through the app: select the second `Accept Profile` row (the exported `Accept Export.app`), `Delete`. Expected: the sheet says `The data folder stays: … is, contains or is inside another shortcut's data folder.` and offers no toggle; Delete moves only the bundle to the Trash. (While the copy exists it shares the data folder, so the toggle in 9.1 is withheld.)
- [ ] **9.1** Select `Accept Profile`, `Delete`. Expected: the sheet offers the data-folder toggle for `~/Desktop/MAD Accept Data`. Turn it on and click Delete. Expected: a second destructive confirmation (`Also move "MAD Accept Data" to the Trash?` with `Move to Trash`), because the folder is outside `~/Library/Application Support/App Duplicator`. Confirm. Expected: `Accept Profile.app` and `MAD Accept Data` are in the Trash and the app is still running.

## Step 10: Claude Desktop after Rebuild All (Mike)

- [ ] **10.1** (Mike) `Launch` on `Claude Work`, then on `Claude Personal`. Expected: two Dock icons titled `Claude Work` and `Claude Personal`, both rows show the running dot, and each instance is signed in to its own account (as in Phase 2 Step 6). Quit both.

## Step 11: Known Limitations

- [ ] **11.1** Help → Known Limitations. Expected: the list includes (37 entries at HEAD on 2026-10-11; later phases append after these) `Compatibility profiles are advisory`, `Partial profiles need manual review`, `Check Profile Updates is manual and fetches from one host`, `Sandboxed native apps cannot be separated`, `Shortcuts whose names match get a numbered slug` and `Export replaces an existing shortcut by moving it to the Trash`.

## Teardown

Nothing is left to move: `Accept Export.app` (Step 9.0), `Accept Profile.app` and `MAD Accept Data` (Step 9.1) and the first `Accept Export.app` (Step 7.2) are already in the Trash. Keep `~/Library/Application Support/App Duplicator/profiles.json` if Step 6.2 wrote it. Leave `Claude Work.app` and `Claude Personal.app` in place.

## Record

| Step | Date | Result | Notes |
|---|---|---|---|
| 1 | 2026-10-11 | N/A | Installed 0.7.0 (6) used; build step covered by Phase 7 |
| 2 | 2026-10-11 | PASS | 2.1–2.4 badges, hover text and Verified/Partial states as expected |
| 3 | 2026-10-11 | PASS | 3.1–3.3 wizard prefill from the Claude profile; editor Profile section; `Accept Profile` created with env `API_TOKEN` |
| 4 | 2026-10-11 | PASS | 4.1–4.2 Diagnostics shows profile status and masked env; nit: 0.7.0 report lists the app's inherited shell environment (fixed in `537c500`, ships in 0.7.1) |
| 5 | 2026-10-11 | PASS | 5.1–5.4 guard messages shown on choosing the path; 5.3 used the real target folder `~/Library/Application Support/Claude` (doc path fixed); 5.4 accepted with Default button |
| 6 | 2026-10-11 | PASS | 6.1 URL correct; 6.2 success with no cache file (remote `updated` equals bundled, by design; doc made conditional); 6.3 N/A (Mike, Wi-Fi off); 6.4 inline warning + Check Now disabled, Reset to Default removed the defaults key (doc wording fixed) |
| 7 | 2026-10-11 | PASS | 7.1 library-folder alert, Export Anyway, sidebar label `Accept Profile`; 7.2 Replace, Trash line in result sheet, earlier copy in `~/.Trash` as `Accept Export 13-04-29-170.app`; codesign rc=0 (doc fixed) |
| 8 | 2026-10-11 | PASS | 8.1 badge + footer + Rebuild All enabled; 8.2 sheet `Rebuild 1 shortcut?` (count, not names; doc fixed); 8.3 progress; 8.4 results listed only `Accept Profile` (Claude Work/Personal not rebuilt), badge gone, engine 1, codesign rc=0, settings kept |
| 9 | 2026-10-11 | PASS | Export copy had to be trashed first (shared data folder withholds the toggle; doc gained 9.0); then toggle offered, second confirmation `Move to Trash`, both `Accept Profile.app` and `MAD Accept Data` in `~/.Trash`, app still running (pid 8949) |
| 10 | 2026-10-11 | N/A | Mike-only |
| 11 | 2026-10-11 | PASS | All six titles on screen and in the installed binary (`strings`); Help menu item opens `Known Limitations` window |
