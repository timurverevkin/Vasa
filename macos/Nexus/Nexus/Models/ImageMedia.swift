import AppKit
import ImageIO

enum ImageMedia {
    nonisolated static let maxSide: CGFloat = 420

    nonisolated static func fileURL(from src: String) -> URL? {
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return nil }
        if let url = URL(string: src), url.isFileURL { return url }
        if src.hasPrefix("/") { return URL(fileURLWithPath: src) }
        return nil
    }

    nonisolated static func orientedSize(at url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, options),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0, height > 0
        {
            let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
            if (5...8).contains(orientation) {
                return CGSize(width: height, height: width)
            }
            return CGSize(width: width, height: height)
        }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size
    }

    nonisolated static func cardSize(for pixelSize: CGSize, maxSide: CGFloat = maxSide) -> (width: Double, height: Double) {
        let width = max(pixelSize.width, 1)
        let height = max(pixelSize.height, 1)
        let scale = maxSide / max(width, height)
        return (
            max(64, (width * scale).rounded(.toNearestOrAwayFromZero)),
            max(64, (height * scale).rounded(.toNearestOrAwayFromZero))
        )
    }
}
