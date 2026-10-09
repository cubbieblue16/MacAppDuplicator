# Phase 2 acceptance: library app

Manual gate. Automated coverage is `Tools/test-app.sh` (62 tests incl. the FixtureApp end-to-end test). The steps below need a person at the Mac. Steps 5 and 6 need Mike (they launch real apps).

## Step 1: Build

```bash
Tools/build-fixture.sh
Tools/build-app.sh
```

Expected: the second command prints the built `.app` path under `.build/DerivedData`. Open it with `open <path>`.

## Step 2: Library loads existing shortcuts

Expected on first launch: the sidebar's Apps section lists `Claude Work` and `Claude Personal` (built by Phase 1 `madctl`) with the Claude icon, subtitle `Claude <version>`, no `Needs rebuild` badge (engine version is still 1). Web Apps, Files & Folders and Commands sections are hidden.

## Step 3: New Shortcut wizard

1. ⌘N. Kind step: only `Application` is selectable; the other three show `Coming in a later phase`.
2. Target step: grid lists `/Applications`; search filters; choosing an Apple app (TextEdit) shows the compatibility line ending `HOME only` or `unsupported`, and the identity step then locks `Launch mode` to `System Launch`.
3. Choose the fixture instead: drag `.build/fixtures/FixtureApp.app` onto the drop zone. Compatibility reads `verified` or `auto`.
4. Identity: default name `FixtureApp Copy`; switch Icon to `Generated tile` and confirm the preview shows the initials `FC`.
5. Data: leave `Auto`. Note reads `Default: ~/Library/Application Support/App Duplicator/fixtureapp-copy`.
6. Review: Launch plan disclosure shows the executable path inside `FixtureApp.app`, `HOME=` and `CFFIXED_USER_HOME=` additions, and the single warning `untested app; HOME override applied` (the fixture is a native app outside the verified families). Create.

Expected: sheet closes, `FixtureApp Copy` is selected in the sidebar with the generated tile icon, and `~/Applications/App Duplicator/FixtureApp Copy.app` exists.

## Step 4: Editor

1. Change Name to `Fixture Renamed`, Save. Expected: sidebar row renames, selection follows, `~/Applications/App Duplicator/Fixture Renamed.app` exists and `FixtureApp Copy.app` is gone.
2. Add environment variable `API_TOKEN` = `abc`. Expected: the value shows as `••••••` until the eye toggle is pressed. Save.
3. `Diagnostics…`: Environment shows `API_TOKEN=••••••`; `Copy Report` puts the same masked text on the clipboard.
4. `Duplicate…` with name `Fixture Dup`. Expected: second row appears.
5. `Export…` to the Desktop. Expected: sheet shows the `xattr -dr com.apple.quarantine` command; the exported bundle opens in Finder.
6. `Delete…` on `Fixture Dup` with the data toggle off. Expected: the bundle is in the Trash; the app is still running; selection clears.

## Step 5: Launch (Mike)

Select `Fixture Renamed`, press `Launch`. Expected: a Dock tile titled `Fixture Renamed` with the generated tile icon; the sidebar row shows the green running dot within 2 s; `~/Library/Application Support/App Duplicator/fixture-renamed/` exists. Quit the fixture from its Dock menu. Expected: the dot disappears.

## Step 6: Claude Desktop two-account test (Mike)

Same as Phase 1 Steps 3 to 5 in `phase1-claude-desktop.md`, but launched from the library (`Launch` on `Claude Work`, then on `Claude Personal`). Both rows show the running dot while the two instances are open.

## Step 7: Settings, Rebuild All, Known Limitations

1. Settings → General: change the output folder to a temp folder and back. Expected: library rescans without restart.
2. Settings → Signing: the picker lists `Ad-hoc` and `Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`. Choose Developer ID, create a shortcut, run `codesign -dv --verbose=2 <bundle>` in Terminal. Expected: `Authority=Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)` and `Runtime Version`. Switch back to Ad-hoc.
3. Edit `Contents/Info.plist` of `Fixture Renamed.app` and set `MADEngineVersion` to `0`. Expected: within 2 s the row shows `Needs rebuild` and the toolbar `Rebuild All` enables. Run it. Expected: badge clears, `codesign --verify --deep --strict` passes.
4. Help → Known Limitations. Expected: window with the nine entries from `KnownLimitations.all`.

## Teardown

Move `~/Applications/App Duplicator/Fixture Renamed.app` and `~/Library/Application Support/App Duplicator/fixture-renamed` to the Trash. Leave `Claude Work.app` and `Claude Personal.app` in place.

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
