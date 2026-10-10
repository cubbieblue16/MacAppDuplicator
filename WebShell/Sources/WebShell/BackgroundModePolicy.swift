/// Skeleton decisions 4 and 9: background mode takes effect only together with the menu bar icon.
struct BackgroundModePolicy: Equatable, Sendable {
    let showsStatusItem: Bool
    let keepsRunningWhenWindowCloses: Bool

    init(backgroundMode: Bool, menuBarIcon: Bool) {
        showsStatusItem = menuBarIcon
        keepsRunningWhenWindowCloses = backgroundMode && menuBarIcon
    }

    var terminatesAfterLastWindowClosed: Bool { !keepsRunningWhenWindowCloses }
}
