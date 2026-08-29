import AppKit
import ImageIO

enum ImageMedia {
    nonisolated static let maxSide: CGFloat = 420

    /// Decoded-image cache, keyed by source string. Never evicted on scroll/camera
    /// move — once a card has been seen, it stays instant to redraw. NSCache still
    /// drops entries under real memory pressure, which is the only eviction we want.
    // NSCache is internally thread-safe; Swift concurrency just doesn't know that.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// Downsampled async decode via ImageIO (cheap vs a full-res `NSImage(contentsOf:)`
    /// decode on the main thread) — cached after first load so re-entering the
    /// viewport never re-decodes.
    static func loadThumbnail(src: String, maxPixelSize: CGFloat) async -> NSImage? {
        let key = "\(src)#\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = fileURL(from: src) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache.setObject(image, forKey: key)
            return image
        }.value
    }

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
