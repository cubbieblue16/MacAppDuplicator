import CoreGraphics
import Foundation
import ImageIO

/// Size limits applied to untrusted image data (a site's icon, a user-picked file) before any frame is decoded. A
/// small file can declare an enormous canvas (a decompression bomb) or hold thousands of frames; ImageIO's header
/// properties are read first and nothing over the limits is ever allocated.
enum ImageSourceLimits {
    /// Widest or tallest frame that is decoded, in pixels.
    static let maxPixelDimension = 4096
    /// Most frames a source may hold (an ICO normally has under 10).
    static let maxFrameCount = 64

    /// True when frame `index` declares a size in `1...maxPixelDimension` on both axes. Reads the header only.
    static func frameIsWithinLimits(_ source: CGImageSource, index: Int) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return false }
        return (1...maxPixelDimension).contains(width) && (1...maxPixelDimension).contains(height)
    }

    /// The frames that may be decoded, or nil when the source holds more than `maxFrameCount`.
    static func decodableFrameIndexes(in source: CGImageSource) -> [Int]? {
        let count = CGImageSourceGetCount(source)
        guard count <= maxFrameCount else { return nil }
        return (0..<count).filter { frameIsWithinLimits(source, index: $0) }
    }
}
