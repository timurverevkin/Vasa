import AppKit
import Foundation

/// Opens Google Lens for a canvas image.
///
/// There is no public Google Lens API, so a local image can only reach Lens as a
/// multipart POST **from the browser**, where the request carries the user's own
/// Google session cookies — an app-side upload comes back as "Expired visual search".
///
/// The bridge page is deliberately a `file://` document, and the image is inlined
/// into it as base64. That is not laziness: a `file://` page has an *opaque* origin,
/// so the browser sends `Origin: null` with the POST, which is what Lens accepts.
/// Serving the same page from a loopback HTTP server instead sends a real
/// `Origin: http://127.0.0.1:<port>` and Lens answers **403** (measured), which
/// surfaces as a blank tab. The opaque origin also rules out `fetch()` for the
/// image bytes (CORS blocks it on `file://`), hence the base64 inline.
enum LensUpload {
    enum UploadError: Error {
        case unreadable
        case writeFailed
    }

    static let lensHome = URL(string: "https://lens.google.com/")!

    /// Root for bridge folders, so leftovers are easy to find and sweep.
    private static var bridgeRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vasa-lens", isDirectory: true)
    }

    /// Write a one-shot HTML bridge and open it in the default browser (new tab).
    @MainActor
    static func openInBrowser(src: String) async throws {
        // Already public — Lens can fetch it directly, no bridge and no temp file.
        if let direct = directUploadURL(for: src) {
            open(direct)
            return
        }

        let payload = try await ImageMedia.downscaledJPEG(src: src)
        let htmlURL = try writeBridgeHTML(jpeg: payload.data, width: payload.width, height: payload.height)
        openInDefaultBrowser(htmlURL)

        // Best-effort prompt cleanup; `sweepLeftovers()` is the guarantee, since the
        // app may well quit before this fires.
        let folder = htmlURL.deletingLastPathComponent()
        Task.detached {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Lens can pull a publicly reachable image itself — the most robust path, when available.
    /// (A loopback URL is useless here: Google fetches it server-side.)
    static func directUploadURL(for src: String) -> URL? {
        guard src.hasPrefix("http://") || src.hasPrefix("https://") else { return nil }
        guard let encoded = src.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://lens.google.com/uploadbyurl?url=\(encoded)")
    }

    @MainActor
    static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config)
    }

    /// A plain `open(fileURL)` hands `.html` to whatever app claims the extension —
    /// an editor, for many developers. Resolve the handler for `https` instead, which
    /// is by definition the user's browser, and open the file with that.
    @MainActor
    private static func openInDefaultBrowser(_ fileURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let probe = URL(string: "https://example.com"),
              let browser = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else {
            NSWorkspace.shared.open(fileURL, configuration: config)
            return
        }
        NSWorkspace.shared.open([fileURL], withApplicationAt: browser, configuration: config)
    }

    /// Remove bridge folders left behind by an earlier run (or by a quit mid-flight).
    /// Cheap, and the only cleanup that actually holds across app termination.
    nonisolated static func sweepLeftovers() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: bridgeRoot, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Bridge file

    nonisolated private static func writeBridgeHTML(jpeg: Data, width: Int, height: Int) throws -> URL {
        let fm = FileManager.default
        let folder = bridgeRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // 0700 — the payload is the user's own image sitting in a shared temp dir.
        try fm.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let htmlURL = folder.appendingPathComponent("open.html")
        let st = Int(Date().timeIntervalSince1970 * 1000)
        let b64 = jpeg.base64EncodedString()
        let w = max(1, width)
        let h = max(1, height)
        // The form POST is a navigation, not an XHR, so CORS does not apply — it
        // carries the browser's Google cookies exactly like a manual upload.
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <title>Opening Google Lens…</title></head>
        <body style="font:14px -apple-system,BlinkMacSystemFont,sans-serif;padding:28px;color:#222">
        <p id="msg">Opening Google Lens…</p>
        <form id="f" method="POST" enctype="multipart/form-data" style="display:none"
          action="https://lens.google.com/v3/upload?ep=ccm&amp;s=&amp;st=\(st)">
          <input type="file" name="encoded_image" id="img" />
          <input type="hidden" name="processed_image_dimensions" value="\(w),\(h)" />
        </form>
        <script>
        (() => {
          try {
            const bin = atob("\(b64)");
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            const dt = new DataTransfer();
            dt.items.add(new File([bytes], "image.jpg", { type: "image/jpeg" }));
            document.getElementById("img").files = dt.files;
            document.getElementById("f").submit();
          } catch (e) {
            // The image is already on the clipboard — Lens accepts a paste.
            document.getElementById("msg").textContent =
              "Could not hand the image to Lens automatically. Opening Lens — press ⌘V to paste it.";
            setTimeout(() => { location.href = "https://lens.google.com/"; }, 1500);
          }
        })();
        </script>
        </body></html>
        """
        guard let data = html.data(using: .utf8) else { throw UploadError.writeFailed }
        try data.write(to: htmlURL, options: .atomic)
        return htmlURL
    }
}
