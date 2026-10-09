import AppKit

// Tiny fixture app used by the integration tests and the Dock smoke check.
// Compiled by Tools/build-fixture.sh (Swift 5 mode); not part of the SwiftPM package.

let environment = ProcessInfo.processInfo.environment

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "MAD Fixture"
window.center()
window.makeKeyAndOrderFront(nil)

if let dumpPath = environment["MAD_FIXTURE_DUMP"] {
    let payload: [String: Any] = [
        "bundlePath": Bundle.main.bundlePath,
        "homeDirectory": NSHomeDirectory(),
        "arguments": CommandLine.arguments,
        "environment": environment,
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: dumpPath), options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("FixtureApp: dump failed: \(error)\n".utf8))
    }
}

let lifetime = environment["MAD_FIXTURE_LIFETIME"].flatMap { Double($0) } ?? 3
Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { _ in
    NSApp.terminate(nil)
}

app.activate(ignoringOtherApps: true)
app.run()
