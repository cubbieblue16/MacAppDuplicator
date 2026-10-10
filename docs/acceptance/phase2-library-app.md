# Phase 2 acceptance: library app

Manual gate. Automated coverage is `Tools/test-app.sh` (108 tests incl. the FixtureApp end-to-end test). The steps below need a person at the Mac. Steps 5 and 6 need Mike (they launch real apps).

Before you start:

- The Mac is online. New shortcuts are signed with the default Developer ID identity (Step 7.2), and Developer ID signing fetches a secure timestamp from Apple.
- The steps assume default settings. `defaults read com.mikekuta.MacAppDuplicator` shows anything an earlier build stored (`outputFolderPath`, `libraryFolderPaths`, `signingIdentity`, `homeSymlinkEntries`). To start clean, quit App Duplicator and run `defaults delete com.mikekuta.MacAppDuplicator`.

## Step 1: Build

```bash
Tools/build-fixture.sh
Tools/build-app.sh --configuration Release
```

Expected: the second command prints `<repo>/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app`. Open it with `open "<path>"` (the name contains spaces).

## Step 2: Library loads existing shortcuts

Expected on first launch: the sidebar's Apps section lists `Claude Work` and `Claude Personal` (built by Phase 1 `madctl`) with the Claude icon, subtitle `Claude <version>`, no `Needs rebuild` badge (engine version is still 1). Web Apps, Files & Folders and Commands sections are hidden.

## Step 3: New Shortcut wizard

1. ⌘N. Kind step: only `Application` is selectable; `Web App`, `File or Folder` and `Command` show `Coming in a later phase`. Next.
2. Target step: the grid lists the apps in `/Applications` and `~/Applications`, and `Search applications` filters it. Apple's own apps live in `/System/Applications`, which the grid does not scan: click `Browse…` (the panel opens on `/Applications`), press ⇧⌘G, go to `/System/Applications`, select `TextEdit` and click `Open`. Expected: the line under the drop zone reads `TextEdit <version> · HOME only`. Next. Expected: `Launch mode` shows `System Launch` and is locked. Back. (Phase 2 never shows `Verified` or `Unsupported`; those badges come from profiles in Phase 3.)
3. Choose the fixture instead: drag `.build/fixtures/FixtureApp.app` onto the drop zone. Expected: the line reads `FixtureApp <version> · HOME only` (the fixture is a native app). Next.
4. Identity: default name `FixtureApp Copy`; `Launch mode` is `Dock Shortcut` and unlocked again. Switch Icon to `Generated tile` and confirm the preview shows the initials `FC`. Next.
5. Data: leave `Auto`. Note reads `Default: ~/Library/Application Support/App Duplicator/fixtureapp-copy`. Next.
6. Review: `Compatibility` reads `HOME only`. The `Launch plan` disclosure shows the executable path inside `FixtureApp.app`, `HOME=` and `CFFIXED_USER_HOME=` additions, and the single warning `untested app; HOME override applied` (the fixture is a native app outside the verified families). Create.

Expected: sheet closes, `FixtureApp Copy` is selected in the sidebar with the generated tile icon, and `~/Applications/App Duplicator/FixtureApp Copy.app` exists. Its data folder does not exist yet: the launcher creates it on first launch (Step 5).

## Step 4: Editor

1. Change Name to `Fixture Renamed`, Save. Expected: sidebar row renames, selection follows, `~/Applications/App Duplicator/Fixture Renamed.app` exists and `FixtureApp Copy.app` is gone. `Data folder` still ends in `App Duplicator/fixtureapp-copy`: a rename never moves the data folder.
2. In Environment, type `API_TOKEN` in the empty row's Name field. Expected: its Value field turns into a secure field, so `abc` shows as dots while you type it. Click the add button (⊕). Expected: the new row's value shows as `••••••` until its eye toggle is pressed. Save.
3. `Diagnostics…`. Expected: `Target` shows the `FixtureApp.app` path the launcher would start, with no `Stored path` row (that row appears only when the stored path differs); Environment shows `API_TOKEN=••••••`; `Copy Report` puts the same masked text on the clipboard. Done.
4. `Duplicate`; the prompt suggests `Fixture Renamed Copy`; enter `Fixture Dup` and confirm. Expected: a second row `Fixture Dup` appears and is selected.
5. Select `Fixture Renamed`, then `Export…`. Expected: the save panel opens on the Desktop with the name `Fixture Renamed.app`. Save. Expected: the Export Shortcut sheet says the exported shortcut is signed with `Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`, shows `xattr -dr com.apple.quarantine '/Users/cubbieblue16/Desktop/Fixture Renamed.app'` (the path in single quotes) with a `Copy Command` button, and an orange notice that environment values travel in plain text, naming `API_TOKEN`. `~/Desktop/Fixture Renamed.app` exists. Done.
6. Select `Fixture Dup`, then `Delete`. Expected: the sheet offers no data-folder toggle and reads `No data folder exists at /Users/cubbieblue16/Library/Application Support/App Duplicator/fixture-dup.` (the copy was never launched). Delete. Expected: the bundle is in the Trash; the app is still running; selection clears.

## Step 5: Launch (Mike)

Select `Fixture Renamed`, press `Launch`. Expected: a Dock tile titled `Fixture Renamed` with the generated tile icon; the sidebar row shows the green running dot within 2 s; `~/Library/Application Support/App Duplicator/fixtureapp-copy/` now exists (the data folder chosen at creation, kept through the rename), and so does the launcher log `~/Library/Logs/App Duplicator/Fixture Renamed.log`. Quit the fixture from its Dock menu. Expected: the dot disappears.

## Step 6: Claude Desktop two-account test (Mike)

Same as Phase 1 Steps 3 to 5 in `phase1-claude-desktop.md`, but launched from the library (`Launch` on `Claude Work`, then on `Claude Personal`). Both rows show the running dot while the two instances are open.

## Step 7: Settings, Rebuild All, Known Limitations

1. Settings → General: Output folder `Choose…`, create and choose an empty folder (for example `~/Desktop/MAD Temp`). Expected, without a restart: the sidebar empties (only the `Apps` header stays) and the detail pane shows the empty-library view. Click `Reset to Default`. Expected: `Claude Work`, `Claude Personal` and `Fixture Renamed` come back.
2. Settings → Signing. Expected: the picker already shows `Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`, the default when a Developer ID Application identity is in the keychain; its menu also lists `Ad-hoc` and any other valid codesigning identity. Leave it as is: picking an entry stores an explicit choice in place of the default. Create a fixture shortcut named `Fixture Signed` with the wizard (as in Step 3, defaults otherwise), then run:

   ```bash
   codesign -dv --verbose=2 ~/Applications/App\ Duplicator/Fixture\ Signed.app 2>&1 | grep -E '^(Authority|Runtime Version|Timestamp)='
   ```

   Expected: the first `Authority=` line is `Authority=Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`, plus a `Timestamp=` and a `Runtime Version=` line. If you did change the picker, restore the default: quit App Duplicator, run `defaults delete com.mikekuta.MacAppDuplicator signingIdentity`, and reopen it.
3. Mark `Fixture Renamed` as built by an older engine (this also breaks its signature until the rebuild):

   ```bash
   plutil -replace MADEngineVersion -integer 0 ~/Applications/App\ Duplicator/Fixture\ Renamed.app/Contents/Info.plist
   ```

   The folder watcher sees bundles added, removed or renamed, not edits inside a bundle, so choose View → Refresh (⌘R). Expected: the row shows `Needs rebuild`, the `Fixture Renamed` editor footer reads `Built by an older engine version (0, current 1). Regenerate to update.`, and the toolbar `Rebuild All` enables. Click it and confirm with `Rebuild`. Expected: the badge clears, `Rebuild All` disables again, and `codesign --verify --deep --strict ~/Applications/App\ Duplicator/Fixture\ Renamed.app` exits 0 with no output.
4. Help → Known Limitations. Expected: a `Known Limitations` window with the 14 entries from `KnownLimitations.all`.

## Teardown

Move these to the Trash:

- `~/Applications/App Duplicator/Fixture Renamed.app` (Steps 3 and 4)
- `~/Applications/App Duplicator/Fixture Signed.app` (Step 7.2; never launched, so it has no data folder or log)
- `~/Desktop/Fixture Renamed.app` (the Step 4.5 export)
- `~/Library/Application Support/App Duplicator/fixtureapp-copy` (created by the Step 5 launch)
- `~/Library/Logs/App Duplicator/Fixture Renamed.log` (the Step 5 launcher log)
- the Step 7.1 temp folder (for example `~/Desktop/MAD Temp`)

`Fixture Dup.app` is already in the Trash (Step 4.6). Leave `Claude Work.app` and `Claude Personal.app` in place.

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
