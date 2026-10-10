import JavaScriptCore
import XCTest
@testable import DuplicatorCore

/// Runs the injected scripts in a bare JavaScriptCore context with stubbed `window.webkit.messageHandlers`, so the
/// tests cover behaviour, not just text. `window` is the global object; `crypto.randomUUID` is deterministic.
final class WebShellScriptsTests: XCTestCase {
    private static let harness = """
    var window = this;
    var navigator = {};
    var posted = { badge: [], notification: [] };
    var counter = 0;
    var crypto = {
      randomUUID: function () {
        counter += 1;
        var tail = ('000000000000' + counter).slice(-12);
        return 'AAAAAAAA-BBBB-4CCC-8DDD-' + tail;
      }
    };
    window.webkit = { messageHandlers: {
      madBadge: { postMessage: function (message) { posted.badge.push(message); } },
      madNotification: { postMessage: function (message) { posted.notification.push(message); } }
    } };
    """

    private func makeContext(harness: String = WebShellScriptsTests.harness) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(harness)
        return context
    }

    private func json(_ context: JSContext, _ expression: String) throws -> String {
        try XCTUnwrap(context.evaluateScript("JSON.stringify(\(expression))")?.toString())
    }

    // MARK: constants

    func testHandlerNamesAndClickScript() throws {
        XCTAssertEqual(WebShellScripts.badgeHandlerName, "madBadge")
        XCTAssertEqual(WebShellScripts.notificationHandlerName, "madNotification")
        XCTAssertEqual(WebShellScripts.notificationClickedFunctionName, "__madNotificationClicked")
        let id = try XCTUnwrap(UUID(uuidString: "5B0D2C1E-8F3A-4C57-9E11-2A6D4B7C9F10"))
        XCTAssertEqual(
            WebShellScripts.notificationClickedScript(id: id),
            #"window.__madNotificationClicked("5b0d2c1e-8f3a-4c57-9e11-2a6d4b7c9f10")"#
        )
    }

    func testScriptsMentionTheirHandlers() {
        XCTAssertTrue(WebShellScripts.badgeBridge.contains("window.webkit.messageHandlers.madBadge"))
        XCTAssertTrue(WebShellScripts.notificationShim.contains("window.webkit.messageHandlers.madNotification"))
        XCTAssertTrue(WebShellScripts.notificationShim.contains("crypto.randomUUID()"))
        XCTAssertTrue(WebShellScripts.notificationShim.contains("window.__madNotificationClicked"))
    }

    // MARK: badge bridge

    func testBadgeBridgePostsCounts() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.badgeBridge)
        context.evaluateScript("navigator.setAppBadge(5)")
        context.evaluateScript("navigator.setAppBadge('7')")
        context.evaluateScript("navigator.setAppBadge(2.9)")
        XCTAssertEqual(try json(context, "posted.badge"), #"[{"count":5},{"count":7},{"count":2}]"#)
    }

    func testBadgeBridgeClears() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.badgeBridge)
        context.evaluateScript("navigator.setAppBadge(0); navigator.setAppBadge(); navigator.setAppBadge(-3); navigator.setAppBadge('x'); navigator.clearAppBadge()")
        XCTAssertEqual(try json(context, "posted.badge"), "[{},{},{},{},{}]")
    }

    func testBadgeBridgeReturnsPromises() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.badgeBridge)
        XCTAssertEqual(context.evaluateScript("typeof navigator.setAppBadge(1).then")?.toString(), "function")
        XCTAssertEqual(context.evaluateScript("typeof navigator.clearAppBadge().then")?.toString(), "function")
    }

    func testBadgeBridgeDoesNothingWithoutTheHandler() throws {
        let context = try makeContext(harness: "var window = this; var navigator = {};")
        context.evaluateScript(WebShellScripts.badgeBridge)
        XCTAssertEqual(context.evaluateScript("typeof navigator.setAppBadge")?.toString(), "undefined")
    }

    // MARK: notification shim

    func testNotificationPostsIdTitleBodyTag() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("new Notification('Alice', { body: 'Hello', tag: 'chat-1', icon: 'x.png', data: { secret: 1 } })")
        XCTAssertEqual(
            try json(context, "posted.notification"),
            #"[{"id":"aaaaaaaa-bbbb-4ccc-8ddd-000000000001","title":"Alice","body":"Hello","tag":"chat-1"}]"#
        )
        let keys = try json(context, "Object.keys(posted.notification[0]).sort()")
        XCTAssertEqual(keys, #"["body","id","tag","title"]"#)
        let id = try XCTUnwrap(context.evaluateScript("posted.notification[0].id")?.toString())
        XCTAssertNotNil(UUID(uuidString: id))
    }

    func testNotificationDefaultsForMissingOptions() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("new Notification('Only title'); new Notification(42, null)")
        XCTAssertEqual(
            try json(context, "posted.notification.map(function (m) { return [m.title, m.body, m.tag]; })"),
            #"[["Only title","",""],["42","",""]]"#
        )
    }

    func testPermissionIsGranted() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        XCTAssertEqual(context.evaluateScript("Notification.permission")?.toString(), "granted")
        context.evaluateScript("var resolved; Notification.requestPermission().then(function (value) { resolved = value; });")
        XCTAssertEqual(context.evaluateScript("resolved")?.toString(), "granted")
        context.evaluateScript("var viaCallback; Notification.requestPermission(function (value) { viaCallback = value; });")
        XCTAssertEqual(context.evaluateScript("viaCallback")?.toString(), "granted")
    }

    func testCloseTrimsTheRegistryAndPostsClose() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("var n = new Notification('A'); var closed = 0; n.onclose = function () { closed += 1; }; n.close(); n.close();")
        XCTAssertEqual(
            try json(context, "posted.notification[1]"),
            #"{"id":"aaaaaaaa-bbbb-4ccc-8ddd-000000000001","close":true}"#
        )
        XCTAssertEqual(try json(context, "posted.notification.length"), "2", "the second close() is a no-op")
        XCTAssertEqual(context.evaluateScript("closed")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000001')")?.toBool(), false)
    }

    func testClickDispatchesToOnclickAndListeners() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("""
        var log = [];
        var n = new Notification('A');
        n.onclick = function (event) { log.push('onclick:' + event.type + ':' + (event.target === n)); };
        n.addEventListener('click', function () { log.push('listener'); });
        """)
        let script = WebShellScripts.notificationClickedScript(id: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-000000000001")))
        XCTAssertEqual(context.evaluateScript(script)?.toBool(), true)
        XCTAssertEqual(try json(context, "log"), #"["onclick:click:true","listener"]"#)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('AAAAAAAA-BBBB-4CCC-8DDD-000000000001')")?.toBool(), true, "ids match case-insensitively")
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('00000000-0000-4000-8000-000000000000')")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('<script>')")?.toBool(), false)
    }

    func testRemovedListenerDoesNotFire() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("var hits = 0; var n = new Notification('A'); var l = function () { hits += 1; }; n.addEventListener('click', l); n.removeEventListener('click', l);")
        context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000001')")
        XCTAssertEqual(context.evaluateScript("hits")?.toInt32(), 0)
    }

    func testRegistryKeepsOnlyTheNewestHundred() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("for (var i = 0; i < 101; i++) { new Notification('n' + i); }")
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000001')")?.toBool(), false, "oldest evicted")
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000002')")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000101')")?.toBool(), true)
    }

    func testFallbackIdWhenRandomUUIDIsMissing() throws {
        let harness = Self.harness.replacingOccurrences(
            of: "randomUUID: function",
            with: "getRandomValues: function (array) { for (var i = 0; i < array.length; i++) { array[i] = (i * 37 + 11) % 256; } return array; },\n  notRandomUUID: function"
        )
        let context = try makeContext(harness: harness)
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("new Notification('A')")
        let id = try XCTUnwrap(context.evaluateScript("posted.notification[0].id")?.toString())
        let parsed = try XCTUnwrap(UUID(uuidString: id), id)
        XCTAssertEqual(parsed.uuidString.lowercased(), id)
        XCTAssertEqual(id.dropFirst(14).first, "4", "version nibble")
    }

    func testShimIsInstalledOnce() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("var first = window.Notification;")
        context.evaluateScript(WebShellScripts.notificationShim)
        XCTAssertEqual(context.evaluateScript("window.Notification === first")?.toBool(), true)
    }

    func testShimDoesNothingWithoutTheHandler() throws {
        let context = try makeContext(harness: "var window = this;")
        context.evaluateScript(WebShellScripts.notificationShim)
        XCTAssertEqual(context.evaluateScript("typeof window.Notification")?.toString(), "undefined")
    }
}
