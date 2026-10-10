/// Remembers which windows were hidden on purpose (background mode hides popups with the main window) so that
/// bringing the app back can show exactly those again. Holds windows by identity; a window that closes while hidden
/// must be dropped with `forget` so no dead window is retained. Pure bookkeeping, tested without real windows.
struct HiddenWindowRegistry<Window: AnyObject> {
    private(set) var windows: [Window] = []

    var isEmpty: Bool { windows.isEmpty }

    /// Adds `newlyHidden` windows; a window already remembered is not added twice.
    mutating func remember(_ newlyHidden: [Window]) {
        for window in newlyHidden where !windows.contains(where: { $0 === window }) {
            windows.append(window)
        }
    }

    /// Drops a window that closed.
    mutating func forget(_ window: Window) {
        windows.removeAll { $0 === window }
    }

    /// Returns every remembered window, oldest first, and clears the registry.
    mutating func takeAll() -> [Window] {
        defer { windows.removeAll() }
        return windows
    }
}
