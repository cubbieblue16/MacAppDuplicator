import AppKit
import DuplicatorCore

// Entry point of a web-app shortcut (skeleton decision 2). Top-level code runs on the main actor.
// The shell never execs, so the process keeps the shortcut's bundle identity (decision 14).
let shortcutName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
let logger = LaunchLogger(name: shortcutName)
logger.log("start pid=\(getpid()) bundle=\(Bundle.main.bundlePath)")

let shell = loadShellConfigOrExit(logger: logger)

let app = NSApplication.shared
let appDelegate = WebShellAppDelegate(shell: shell, logger: logger)  // global: NSApplication.delegate is weak
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
