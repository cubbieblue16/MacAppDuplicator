import AppKit
import SwiftUI

/// The editor's 64-point icon preview. It draws what `IconPreviewSource` resolved from the draft, so a new icon mode,
/// custom file or name shows before Save (final review M4).
struct IconPreview: View {
    let source: IconPreviewSource

    var body: some View {
        if let image = Self.image(for: source) {
            Image(nsImage: image).resizable().frame(width: 64, height: 64)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 48)).foregroundStyle(.secondary).frame(width: 64, height: 64)
        }
    }

    /// The image for `source`; nil when there is nothing to draw or the file is not a readable image.
    static func image(for source: IconPreviewSource) -> NSImage? {
        switch source {
        case .file(let url):
            return NSImage(contentsOf: url)
        case .generated(let initials):
            return NSImage(cgImage: IconRenderer.generatedTile(initials: initials, size: 128), size: NSSize(width: 64, height: 64))
        case .placeholder:
            return nil
        }
    }
}
