# Phase 1 acceptance: Claude Desktop two-account test

Manual gate. Steps 3 to 5 need Mike present; sign-ins are his.

Target: `/Applications/Claude.app` (Electron, not sandboxed, bundle id `com.anthropic.claudefordesktop`, original data dir `~/Library/Application Support/Claude`).

## Step 2: Generate (no sign-in needed)

```bash
swift build -c release
.build/release/madctl new /Applications/Claude.app --name "Claude Work"
.build/release/madctl new /Applications/Claude.app --name "Claude Personal"
```

Expected stdout: `~/Applications/App Duplicator/Claude Work.app` and `~/Applications/App Duplicator/Claude Personal.app` (expanded paths).

## Step 3: Launch (Mike)

```bash
open ~/Applications/App\ Duplicator/Claude\ Work.app ~/Applications/App\ Duplicator/Claude\ Personal.app
```

Expected: two Claude windows open. Mike signs in to a different account in each window.

## Step 4: Verify

- Distinct data dirs:
  ```bash
  ps -axo pid=,args= | grep -F 'Claude.app/Contents/MacOS/Claude --user-data-dir=' | grep -v grep
  ```
  Expected: exactly two lines, one ending `.../App Duplicator/claude-work`, one ending `.../App Duplicator/claude-personal`.
- Two Dock tiles named `Claude Work` and `Claude Personal`, both with the Claude icon (visual).
- Own config files: in each window open Settings, Developer, Edit Config (creates the file), then:
  ```bash
  ls -l ~/Library/Application\ Support/App\ Duplicator/claude-work/claude_desktop_config.json ~/Library/Application\ Support/App\ Duplicator/claude-personal/claude_desktop_config.json
  ```
  Expected: two distinct files; the original `~/Library/Application Support/Claude` is untouched.
- `lsappinfo` and Activity Monitor show `com.anthropic.claudefordesktop` for both processes. Expected: this is expected (spec section 4.1): LaunchServices re-registers the target at check-in while the Dock tile keeps the shortcut's name and icon.
- Logs:
  ```bash
  tail -5 ~/Library/Logs/App\ Duplicator/Claude\ Work.log
  ```
  Expected: shows the `exec` line and no secret values.

## Step 5: Teardown

Quit both instances; delete only the two shortcut bundles:

```bash
rm -rf ~/Applications/App\ Duplicator/Claude\ Work.app ~/Applications/App\ Duplicator/Claude\ Personal.app
```

Expected: both bundles gone. The data folders stay until Mike removes them (shortcut and data are separate, spec section 2).

## Results (date, macOS build)

Pending: Steps 3 to 5 require Mike present (sign-ins). Steps 1 and 2 done 2026-10-09 on macOS 27.0.1 (26A434).

Step 2 stdout (`madctl new`, release binaries built from HEAD~1 sources, no source change since):

```
$ .build/release/madctl new /Applications/Claude.app --name "Claude Work"
/Users/cubbieblue16/Applications/App Duplicator/Claude Work.app
$ .build/release/madctl new /Applications/Claude.app --name "Claude Personal"
/Users/cubbieblue16/Applications/App Duplicator/Claude Personal.app
```

Step 2: pass (both paths match the expected expanded paths).

Step 4 results:

- Distinct data dirs: pending
- Two Dock tiles with Claude icon: pending
- Own config files, original data dir untouched: pending
- `lsappinfo` / Activity Monitor bundle id: pending
- Logs show `exec` line, no secrets: pending
