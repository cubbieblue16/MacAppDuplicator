# Promoting a profile from partial to verified

A profile's `status` in `Packages/CompatProfiles/Resources/profiles.json` is `partial` until someone has checked the app end to end on a real Mac, and only then `verified`. The badge shows `Verified` for a verified profile and ignores a partial one (`CompatBadge.badge(for:profile:)`), so promote only what you have checked yourself. A promotion is advisory: it records that the profile worked on one Mac with the app version installed at the time.

## Before you start

- The app is installed at `/Applications/<App>.app` at the version you want to vouch for.
- You have a second account for the app (different from the one the original app is signed in to).
- A current App Duplicator build (`Tools/build-app.sh`) and a clean checkout of `main`.

## Steps

### 1. Re-check the bundle identifier

```bash
mdls -name kMDItemCFBundleIdentifier /Applications/<App>.app
```

Expected: `kMDItemCFBundleIdentifier = "<bundle id>"`, matching the profile's key under `apps` exactly (case included). If it differs, the profile never matches the app: fix the key instead of promoting.

### 2. Create a shortcut with the profile defaults

In App Duplicator, ⌘N, `Application`, select the app, name the shortcut `<App> Promote`, keep the prefilled arguments and environment, leave Data on `Auto` and create it. Expected: the editor's Profile section shows the match line for this profile with status `partial`.

### 3. Sign in to a second account and confirm a separate data folder

Launch `<App> Promote` and sign in to the second account. Expected: `~/Library/Application Support/App Duplicator/<slug>` (the data folder shown in the editor) now holds the app's data, and the original app, launched separately, is still signed in to the first account. Quit both and relaunch both: each comes back signed in to its own account.

### 4. Confirm two Dock icons

With the original app and `<App> Promote` both running, expected: two Dock icons, one titled `<App> Promote`, and both windows usable at the same time. Quit both.

### 5. Edit the profile

In `Packages/CompatProfiles/Resources/profiles.json`:

- set the app's `"status"` to `"verified"`;
- rewrite its `"notes"` to say what was checked, for example `"Verified 2026-10-10 on macOS 26.1 with <App> 1.2.3: second account, separate data folder, two Dock icons."` (drop wording such as `Not launch-tested yet.`);
- set the top-level `"updated"` to today's date (`date +%F`). It must be a real `YYYY-MM-DD` date and strictly later than the value it replaces: the app compares this date (`ProfileCatalog.isNewer`) to decide whether a downloaded or cached `profiles.json` replaces the bundled one, so an unchanged date can leave people on the old copy. If the file already carries today's date, use tomorrow's (`date -v+1d +%F`).

Check that the file still parses and shows the new status:

```bash
python3 -I -c '
import json
doc = json.load(open("Packages/CompatProfiles/Resources/profiles.json"))
print(doc["updated"], doc["apps"]["<bundle id>"]["status"])
'
```

Expected: the new date followed by `verified`.

### 6. Run the profile tests

```bash
swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3
```

Expected: `Executed … tests, with 0 failures` and no `error:` lines.

### 7. Commit

```bash
git add Packages/CompatProfiles/Resources/profiles.json
git commit -m "Profiles: promote <App> to verified"
git push origin main
```

The next app build bundles the new seed. Existing installs pick it up through Check Profile Updates once the commit is on `main`, because the default profiles URL points at this repository's `main` branch. Move `<App> Promote` and its data folder to the Trash when you are done.
