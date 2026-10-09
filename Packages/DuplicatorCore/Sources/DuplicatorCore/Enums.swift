import Foundation

/// What a shortcut launches (spec §3.1). Phase 1 implements `.app` only.
public enum ShortcutKind: String, Codable, Sendable { case app, webApp, file, folder, cli }

/// How the launcher starts the target (spec §4.1).
public enum LaunchMode: String, Codable, Sendable { case dockShortcut, systemLaunch }

/// Data separation strategy (spec §4.3).
public enum DataMode: String, Codable, Sendable { case auto, homeOverride, disabled }

/// Appearance override (spec §4.5).
public enum Appearance: String, Codable, Sendable { case system, light, dark }

/// Target app family detected by `AppInspector` (spec §4.2).
public enum AppFamily: String, Codable, Sendable { case todesktop, electron, chromium, firefox, eclipse, native }

/// How a shortcut's icon is produced (spec §7, Identity section).
/// `copied` copies the target's icon, `custom` converts the file at `ShortcutConfig.customIconPath`,
/// `generated` renders a tile with the shortcut's initials.
public enum IconMode: String, Codable, Sendable { case copied, custom, generated }
