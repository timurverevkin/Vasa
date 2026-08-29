import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Opens Google Lens by submitting the image **from the browser** (same cookies).
/// App-side POST + open redirect causes "Expired visual search".
enum LensUpload {
    enum UploadError: Error {
        case unreadable
        case writeFailed
    }

    /// Write a one-shot HTML bridge and open it in the default browser (new tab).
    @MainActor
    static func openInBrowser(src: String) async throws {
        let payload = try await imagePayload(for: src)
        let htmlURL = try writeBridgeHTML(jpeg: payload.data, width: payload.width, height: payload.height)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await NSWorkspace.shared.open(htmlURL, configuration: config)
        // Clean up shortly after the browser loads the file.
        let folder = htmlURL.deletingLastPathComponent()
        Task.detached {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Bridge file

    nonisolated private static func writeBridgeHTML(jpeg: Data, width: Int, height: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vasa-lens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let htmlURL = folder.appendingPathComponent("open.html")
        let st = Int(Date().timeIntervalSince1970 * 1000)
        let b64 = jpeg.base64EncodedString()
        let w = max(1, width)
        let h = max(1, height)
        // Form POST runs in the browser tab — same session as Google cookies.
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Opening Google Lens…</title></head>
        <body style="font:14px -apple-system,BlinkMacSystemFont,sans-serif;padding:28px;color:#222">
        <p>Opening Google Lens…</p>
        <form id="f" method="POST" enctype="multipart/form-data" style="display:none"
          action="https://lens.google.com/v3/upload?ep=ccm&amp;s=&amp;st=\(st)">
          <input type="file" name="encoded_image" id="img" />
          <input type="hidden" name="processed_image_dimensions" value="\(w),\(h)" />
        </form>
        <script>
        (async () => {
          const b64 = "\(b64)";
          const bin = atob(b64);
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          const file = new File([bytes], "image.jpg", { type: "image/jpeg" });
          const dt = new DataTransfer();
          dt.items.add(file);
          document.getElementById("img").files = dt.files;
          document.getElementById("f").submit();
        })().catch((err) => {
          document.body.textContent = "Could not open Lens: " + err;
        });
        </script>
        </body></html>
        """
        guard let data = html.data(using: .utf8) else { throw UploadError.writeFailed }
        try data.write(to: htmlURL, options: .atomic)
        return htmlURL
    }

    // MARK: - Image

    private static func imagePayload(for src: String) async throws -> (data: Data, width: Int, height: Int) {
        if src.hasPrefix("http://") || src.hasPrefix("https://"), let remote = URL(string: src) {
            let (data, response) = try await URLSession.shared.data(from: remote)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), !data.isEmpty else { throw UploadError.unreadable }
            return try await Task.detached(priority: .userInitiated) {
                try Self.jpegFromData(data)
            }.value
        }

        guard let fileURL = ImageMedia.fileURL(from: src),
              FileManager.default.fileExists(atPath: fileURL.path)
        else { throw UploadError.unreadable }

        return try await Task.detached(priority: .userInitiated) {
            try jpegPayload(from: fileURL)
        }.value
    }

    nonisolated private static func jpegPayload(from fileURL: URL) throws -> (data: Data, width: Int, height: Int) {
        try jpegFromData(Data(contentsOf: fileURL))
    }

    nonisolated private static func jpegFromData(_ data: Data) throws -> (data: Data, width: Int, height: Int) {
        let maxEdge: CGFloat = 1600
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw UploadError.unreadable
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            throw UploadError.unreadable
        }
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutable, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw UploadError.unreadable }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw UploadError.unreadable }
        return (mutable as Data, cgImage.width, cgImage.height)
    }
}
