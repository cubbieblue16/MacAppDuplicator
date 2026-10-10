# Phase 4 acceptance: web apps

Manual gate. Automated coverage is `Tools/test-app.sh` (MacAppDuplicatorTests), `swift test --filter DuplicatorCoreTests`, `swift test --filter CompatProfilesTests` and `swift test --filter IntegrationTests`. The steps below need a person at the Mac. Steps 3, 4 and 5 need Mike: they sign in to a real WhatsApp account and need a second device to send messages. Tick each box as it passes and fill in the Record table.

## Preconditions

- The Mac is online. The bundled profiles carry the `whatsapp` web app preset (`https://web.whatsapp.com`, Chrome user agent), so no profile download is needed.
- Default settings: quit App Duplicator and run `defaults delete com.mikekuta.MacAppDuplicator` (an error saying the domain does not exist is fine).
- No earlier acceptance run left files behind: `ls ~/Applications/App\ Duplicator | grep -i "Acceptance Chat"` prints nothing, and `ls ~/Library/WebKit | grep acceptance-chat` prints nothing.
- Run every command from the repository root.

## Step 1: Build

```bash
Tools/build-app.sh --configuration Release
```

- [ ] **1.1** The command prints `<repo>/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app`. Open it with `open "<path>"` (the name contains spaces). Expected: the library window opens and the app menu's About panel shows `Version 0.4.0 (3)`.

## Step 2: Create a web app

- [ ] **2.1** Press ⌘N. Expected: the kind step offers `Web App` with the subtitle `Any website as its own app`, enabled. Choose it and click Next.
- [ ] **2.2** Expected: the heading `Choose a website`, preset tiles including `WhatsApp`, `Teams` and `Outlook`, and an empty `Website URL` field. Click the `WhatsApp` tile. Expected: the field shows `https://web.whatsapp.com`. Type `ftp://example.com` into the field instead. Expected: the note `Enter an https:// address` and Next is disabled. Click the `WhatsApp` tile again and click Next.
- [ ] **2.3** Identity: set the name to `Acceptance Chat`. Expected: the icon choice defaults to `Fetched from site` (a generated letter tile appears with a note if the fetch failed). Next.
- [ ] **2.4** `Web App Options`: expected `User agent` shows `Chrome`, `Also open in app` lists `whatsapp.com` and `whatsapp.net`, `Menu bar icon` is off and `Keep running in the menu bar when the window closes` is disabled with the hint `Turn on the menu bar icon first`. Leave everything as is and click Next.
- [ ] **2.5** Review. Expected: rows for the name, the address, the user agent and the web data id, and no `Compatibility`, `Profile` or `Launch plan` line. Create. Expected: `Acceptance Chat` appears in the library and its bundle is `~/Applications/App Duplicator/Acceptance Chat.app`.
- [ ] **2.6** `plutil -extract CFBundleIdentifier raw -o - ~/Applications/App\ Duplicator/Acceptance\ Chat.app/Contents/Info.plist` prints `com.mikekuta.appduplicator.acceptance-chat`. Note the web data id shown in the editor's `Web data` row (Step 7) as `<UUID>`; the WebKit folder name is the same id in lowercase.

## Step 3: Login persists across relaunches (Mike)

- [ ] **3.1** In the library, click Launch on `Acceptance Chat`. Expected: a window opens on WhatsApp Web with a QR code, and the Dock shows the `Acceptance Chat` icon.
- [ ] **3.2** Scan the QR code with the phone and wait for the chat list. Expected: signed in.
- [ ] **3.3** Quit with ⌘Q. Launch it again. Expected: the chat list appears without a QR code (the login survived).
- [ ] **3.4** Quit it, restart App Duplicator, launch again. Expected: still signed in. `ls ~/Library/WebKit/com.mikekuta.appduplicator.acceptance-chat/WebsiteDataStore` lists one folder, named with `<UUID>` in lowercase.

## Step 4: Dock badge (Mike)

- [ ] **4.1** With `Acceptance Chat` running and a second window or app in front, send two messages from another device to this WhatsApp account. Expected: the page title shows `(2)` and the Dock icon shows the badge `2`.
- [ ] **4.2** Open the unread chats. Expected: the badge disappears.
- [ ] **4.3** `grep -c badge ~/Library/Logs/App\ Duplicator/Acceptance\ Chat.log` prints a number greater than 0.

## Step 5: Notification click (Mike)

- [ ] **5.1** Send a message while `Acceptance Chat` is in the background. On the first notification macOS asks whether `Acceptance Chat` may send notifications; choose Allow. Expected: a banner titled with the sender's name.
- [ ] **5.2** Switch to another app, send another message and click the banner. Expected: `Acceptance Chat` comes to the front with its window.

## Step 6: Menu bar icon and background mode

- [ ] **6.1** Quit `Acceptance Chat`. In its editor (Step 7 describes the section) switch `Menu bar icon` on, then `Keep running in the menu bar when the window closes` on, and Save. Launch it again.
- [ ] **6.2** Expected: an icon appears in the menu bar. Close the window with ⌘W. Expected: the window closes, the Dock icon disappears and the menu bar icon stays.
- [ ] **6.3** Click the menu bar icon and choose `Show Acceptance Chat`. Expected: the window returns and so does the Dock icon.
- [ ] **6.4** Close the window again, then click the menu bar icon and choose `Quit Acceptance Chat`. Expected: the app quits and the menu bar icon is gone.
- [ ] **6.5** In the editor, switch `Menu bar icon` off. Expected: `Keep running in the menu bar when the window closes` turns off and is disabled with the hint `Turn on the menu bar icon first`. Save.

## Step 7: Editor

Select `Acceptance Chat` in the library.

- [ ] **7.1** Expected: the editor shows Identity and a `Web App` section; there is no Target, Profile, Launch or Advanced section, no `Compatibility` row, and `Launch`, `Reveal in Finder`, `Regenerate`, `Duplicate`, `Export` and `Delete` are enabled. The `Web App` section shows `Website URL`, `User agent`, `Badge pattern`, `Also open in app`, `Menu bar icon`, `Keep running in the menu bar when the window closes`, a read-only `Zoom` of `100%`, and a `Web data` row with `<UUID>` and the button `Remove Web Data…`.
- [ ] **7.2** Record the icon fingerprint: `shasum -a 256 ~/Applications/App\ Duplicator/Acceptance\ Chat.app/Contents/Resources/AppIcon.icns`. Call the printed hash `<ICON>`.
- [ ] **7.3** Change `User agent` to `Safari`, add the line `login.example.com` under `Also open in app`, and click Save. Expected: Save succeeds and the sidebar row stays `Acceptance Chat`.
- [ ] **7.4** Expected after the Save: the `shasum` command from 7.2 prints `<ICON>` again (the fetched icon was kept), the `plutil` command from 2.6 still prints `com.mikekuta.appduplicator.acceptance-chat`, and `Web data` still shows `<UUID>`.
- [ ] **7.5** Rename the shortcut to `Acceptance Chat 2` in Identity and Save. Expected: the bundle is now `Acceptance Chat 2.app`, the bundle identifier is still `com.mikekuta.appduplicator.acceptance-chat`, `Web data` still shows `<UUID>`, and launching it is still signed in to WhatsApp. Rename it back to `Acceptance Chat` and Save.
- [ ] **7.6** Type `ftp://example.com` into `Website URL`. Expected: the message `Enter an https:// address` and Save is disabled. Click Revert. Expected: the original address returns and Save is disabled again.
- [ ] **7.7** Type `(` into `Badge pattern`. Expected: a note that the pattern is not valid and the default `\((\d+)\)` is used. Click Revert.

## Step 8: Remove Web Data

Quit `Acceptance Chat` first if it is running. Replace `<ID>` below with `com.mikekuta.appduplicator.acceptance-chat`.

- [ ] **8.1** Launch `Acceptance Chat` (still signed in), keep it running, and click `Remove Web Data…` in the editor, then `Remove Web Data` in the confirmation. Expected: an alert titled `Could not remove web data` with the text `Quit “Acceptance Chat” before removing its web data.` and nothing is removed. Quit `Acceptance Chat`.
- [ ] **8.2** Before: run `ls ~/Library/WebKit/<ID>/WebsiteDataStore` (one folder named `<UUID>` in lowercase) and `ls ~/Library/Caches/<ID>`. Note both.
- [ ] **8.3** Click `Remove Web Data…`, read the confirmation (it says this signs the shortcut out of every site and cannot be undone), and click `Remove Web Data`. Expected: no alert.
- [ ] **8.4** After: `ls ~/Library/WebKit/<ID>/WebsiteDataStore` no longer lists the `<UUID>` folder (it may report no such directory or print nothing). `ls ~/Library/Caches/<ID>` shows the web cache is gone or empty. The shortcut is still in the library and `Web data` still shows `<UUID>`.
- [ ] **8.5** Launch `Acceptance Chat`. Expected: WhatsApp shows a QR code again (signed out). Quit it. If it is still signed in after 8.3, or 8.4 shows the folder, the web data store location assumed in Deviation 1 of the Phase 4 plan is wrong: stop and report it instead of ticking the box.

## Step 9: Duplicate and Delete

- [ ] **9.1** Duplicate `Acceptance Chat` as `Acceptance Chat Copy`. Expected: the copy's `Web data` shows a different id from the original, and its Web App section keeps the same address and options. Launch the copy briefly, expecting a QR code (it has its own logins), then quit it.
- [ ] **9.2** Delete `Acceptance Chat Copy`. Expected: after the usual confirmation a second question `Also remove web data (logins, cookies, cache)?` with the buttons `Keep Web Data` (the default), `Remove Web Data` and `Cancel`. Click `Cancel`. Expected: nothing was deleted.
- [ ] **9.3** Delete it again and choose `Keep Web Data`. Expected: the shortcut is in the Trash and `ls ~/Library/WebKit/com.mikekuta.appduplicator.acceptance-chat-copy/WebsiteDataStore` still lists a folder.
- [ ] **9.4** Put `Acceptance Chat Copy.app` back into `~/Applications/App Duplicator` from the Trash, wait for it to appear in the library, and delete it again, this time choosing `Remove Web Data`. Expected: the shortcut is in the Trash and the folder from 9.3 is gone. If the delete fails, the shortcut is not trashed and an alert shows why.
- [ ] **9.5** Empty nothing: the Trash holds the two `Acceptance Chat Copy.app` bundles until Teardown.

## Step 10: Diagnostics

- [ ] **10.1** Change the address of `Acceptance Chat` to `https://web.whatsapp.com/?token=mad-secret-4471#x` and Save. Open `Diagnostics…`. Expected: rows `Kind` (`Web app`), `URL` (`https://web.whatsapp.com/`), `User agent` (`Safari`), `Data store` (`<UUID>`), `Background` (`Off`), `Menu bar icon` (`Off`), `Badge pattern` (`\((\d+)\) (default)`), `Also open` (`whatsapp.com, whatsapp.net, login.example.com`), `Zoom` (`100%`), and a log section ending with the lines Step 3 and Step 4 produced. There are no `Target`, `Executable`, `Arguments` or `Environment` entries.
- [ ] **10.2** Click `Copy Report`, then run `pbpaste | grep -c 'mad-secret-4471'`. Expected: `0`. Done. Restore the address to `https://web.whatsapp.com` and Save.

## Step 11: Known Limitations

- [ ] **11.1** Help → Known Limitations. Expected: 24 entries. The last four are `Web apps do not support passkeys`, `Web app zoom is remembered outside the shortcut`, `Web notifications are always allowed, but macOS decides whether they appear` and `Web apps open other sites in your browser`.

## Step 12: Zoom is kept outside the bundle

- [ ] **12.1** Launch `Acceptance Chat`, press ⌘+ three times, quit, launch again. Expected: the page is still zoomed. The editor's `Zoom` still reads `100%`.
- [ ] **12.2** `defaults read com.mikekuta.appduplicator.acceptance-chat MADPageZoom` prints a number above 1. Press ⌘0 in the app, quit, and run the command again. Expected: `1`.

## Teardown

Move only the test items to the Trash (nothing here is deleted outright):

- `~/Applications/App Duplicator/Acceptance Chat.app` (delete it from the library, choose `Remove Web Data`).
- `~/Library/Preferences/com.mikekuta.appduplicator.acceptance-chat.plist`: `mv ~/Library/Preferences/com.mikekuta.appduplicator.acceptance-chat.plist ~/.Trash/` (the preferences daemon may need `killall cfprefsd` before the zoom value disappears).
- `~/Library/Logs/App Duplicator/Acceptance Chat.log` and `Acceptance Chat Copy.log`.
- Empty any leftover `Acceptance Chat Copy.app` bundles from the Trash yourself.

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
| 12 | | | |
