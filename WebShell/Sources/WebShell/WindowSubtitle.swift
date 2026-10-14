import Foundation

/// The address text shown under a window's title. The shell's windows show a page-controlled title (or the
/// shortcut name) and no address bar, so the host is the only cue to which site a window is really showing.
enum WindowSubtitle {
    /// The host of `url` as WebKit reports it (lower-cased; internationalized hosts stay in punycode so a lookalike
    /// is visible), or an empty string for URLs without a host (`about:blank`, `blob:` from nowhere).
    static func text(for url: URL?) -> String {
        guard let host = url?.host(percentEncoded: true), !host.isEmpty else { return "" }
        return host.lowercased()
    }
}
