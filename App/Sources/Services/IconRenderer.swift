import AppKit
import CoreGraphics
import Foundation

/// Generated tile icons and ICNS writing (spec §7 icon modes). ICNS files are produced with `/usr/bin/iconutil`
/// from a temporary `.iconset`, the same route Xcode uses; an `.icns` source is copied as is.
enum IconRenderer {
    enum RenderError: Error, LocalizedError {
        case unreadableImage(String)
        case iconutilFailed(String)
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let path): "Could not read an image from \(path)."
            case .iconutilFailed(let message): "iconutil failed: \(message)"
            case .encodeFailed: "Could not encode the icon as PNG."
            }
        }
    }

    /// The sizes `iconutil` requires, as (pixels, file name).
    private static let iconsetEntries: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    /// Up to two initials from the first two words; "?" for an empty name.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let letters = words.compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// A rounded tile with white initials; the hue is derived from the initials so different shortcuts differ.
    static func generatedTile(initials: String, size: Int) -> CGImage {
        let scale = CGFloat(size) / 1024
        let hue = CGFloat(initials.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: 100 * scale, dy: 100 * scale)
            let path = NSBezierPath(roundedRect: inset, xRadius: 186 * scale, yRadius: 186 * scale)
            let gradient = NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.35, alpha: 1),
                                      ending: NSColor(hue: hue, saturation: 0.65, brightness: 0.75, alpha: 1))
            gradient?.draw(in: path, angle: -60)
            let font = NSFont.systemFont(ofSize: 420 * scale, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let text = NSAttributedString(string: initials, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        var proposed = CGRect(origin: .zero, size: NSSize(width: size, height: size))
        // NSImage drawing handlers always rasterize; the block above guarantees a bitmap at exactly `size` points.
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: [.ctm: AffineTransform(scale: 1)])!
    }

    static func writeICNS(generatedFor name: String, to url: URL) throws {
        let tile = generatedTile(initials: initials(for: name), size: 1024)
        try writeICNS(from: tile, to: url)
    }

    /// `.icns` sources are copied; any other image readable by `NSImage` is resampled into an iconset.
    static func writeICNS(fromImageFile source: URL, to url: URL) throws {
        if source.pathExtension.lowercased() == "icns" {
            try replaceFile(at: url, with: try Data(contentsOf: source))
            return
        }
        guard let image = NSImage(contentsOf: source) else { throw RenderError.unreadableImage(source.path) }
        var proposed = CGRect(origin: .zero, size: NSSize(width: 1024, height: 1024))
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw RenderError.unreadableImage(source.path)
        }
        try writeICNS(from: cg, to: url)
    }

    static func writeICNS(from image: CGImage, to url: URL) throws {
        let iconset = FileManager.default.temporaryDirectory.appending(path: "mad-\(UUID().uuidString).iconset", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }

        for (pixels, fileName) in iconsetEntries {
            let data = try pngData(resampling: image, to: pixels)
            try data.write(to: iconset.appending(path: fileName))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RenderError.iconutilFailed(String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func pngData(resampling image: CGImage, to pixels: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.encodeFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
            throw RenderError.encodeFailed
        }
        return data
    }

    private static func replaceFile(at url: URL, with data: Data) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try data.write(to: url)
    }
}
