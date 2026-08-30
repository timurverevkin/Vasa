import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageMedia {
    nonisolated static let maxSide: CGFloat = 420

    /// Decoded-image cache, keyed by source string. Never evicted on scroll/camera
    /// move — once a card has been seen, it stays instant to redraw. NSCache still
    /// drops entries under real memory pressure, which is the only eviction we want.
    // NSCache is internally thread-safe; Swift concurrency just doesn't know that.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// Synchronous cache peek — lets a view render an already-decoded image on its
    /// first frame instead of flashing a placeholder while an async task starts.
    /// Session-lived: once a thumbnail is decoded it stays available until memory
    /// pressure evicts it, so reopening a project or scrolling the sidebar is instant.
    static func cachedThumbnail(src: String, maxPixelSize: CGFloat) -> NSImage? {
        cache.object(forKey: "\(src)#\(Int(maxPixelSize))" as NSString)
    }

    /// Warms the cache without needing a view on screen — used to prefetch a board's
    /// media after its layout and text have already been painted.
    static func prefetchThumbnail(src: String, maxPixelSize: CGFloat) async {
        _ = await loadThumbnail(src: src, maxPixelSize: maxPixelSize)
    }

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

    enum PayloadError: Error {
        case unreadable
    }

    /// A downscaled JPEG copy of `src` plus its pixel dimensions, for handing an
    /// image to something outside the app. Re-encoding also drops EXIF (GPS included),
    /// which is deliberate — this payload leaves the machine.
    static func downscaledJPEG(
        src: String,
        maxEdge: CGFloat = 1600,
        quality: CGFloat = 0.85
    ) async throws -> (data: Data, width: Int, height: Int) {
        if src.hasPrefix("http://") || src.hasPrefix("https://"), let remote = URL(string: src) {
            let (data, response) = try await URLSession.shared.data(from: remote)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), !data.isEmpty else { throw PayloadError.unreadable }
            return try await Task.detached(priority: .userInitiated) {
                try downscaledJPEG(from: data, maxEdge: maxEdge, quality: quality)
            }.value
        }

        guard let fileURL = fileURL(from: src),
              FileManager.default.fileExists(atPath: fileURL.path)
        else { throw PayloadError.unreadable }

        return try await Task.detached(priority: .userInitiated) {
            try downscaledJPEG(from: Data(contentsOf: fileURL), maxEdge: maxEdge, quality: quality)
        }.value
    }

    nonisolated static func downscaledJPEG(
        from data: Data,
        maxEdge: CGFloat = 1600,
        quality: CGFloat = 0.85
    ) throws -> (data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { throw PayloadError.unreadable }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            throw PayloadError.unreadable
        }
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutable, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PayloadError.unreadable }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PayloadError.unreadable }
        return (mutable as Data, cgImage.width, cgImage.height)
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
