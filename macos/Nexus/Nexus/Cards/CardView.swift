import AppKit
import AVKit
import SwiftUI
import WebKit

struct CardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    let selected: Bool

    var body: some View {
        let clipRadius = contentClipRadius
        content
            .frame(width: card.previewWidth, height: card.previewHeight)
            .modifier(CardClip(radius: clipRadius))
            .modifier(CardComposite(enabled: clipRadius >= 0))
            .overlay {
                if showsChrome {
                    CardSelection(
                        selected: true,
                        showNotch: true,
                        radius: chromeRadius,
                        onResize: { delta in app.scaleCard(card.id, delta: delta) },
                        onEnd: {
                            app.snapSelected()
                            app.saveNow()
                        }
                    )
                }
            }
            .contentShape(Rectangle())
            .zIndex(isEditingText ? 50 : 0)
            .position(x: card.previewWidth / 2 + card.x, y: card.previewHeight / 2 + card.y)
            // Select on press (not delayed tap). Pairing single+double onTapGesture
            // waits for the double-click timeout (~300ms) before selecting.
            .gesture(isEditingText ? nil : pressAndMoveGesture)
            .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
    }

    private var isEditingText: Bool {
        card.kind == .text && app.editingID == card.id
    }

    @ViewBuilder
    private var content: some View {
        switch card.kind {
        case .text: TextCardView(card: card, selected: selected)
        case .note: NoteCardView(card: card)
        case .image: ImageCardView(card: card)
        case .link: LinkCardView(card: card)
        case .audio: AudioCardView(card: card)
        case .video: VideoCardView(card: card)
        case .shortcut, .folder: ShortcutCardView(card: card)
        case .draw: DrawCardView(card: card)
        case .youtube: YouTubeCardView(card: card)
        }
    }

    private var showsChrome: Bool {
        guard selected else { return false }
        switch card.kind {
        case .audio: return false
        case .text: return !isEditingText
        default: return true
        }
    }

    private var chromeRadius: CGFloat {
        switch card.kind {
        case .note, .audio, .image, .video, .youtube, .shortcut, .folder: Format.cardRadius
        case .link: card.showsRichLink ? Format.cardBorderedRadius : Format.cardRadius
        case .text: 8
        default: 14
        }
    }

    private var contentClipRadius: CGFloat {
        switch card.kind {
        case .image, .video, .youtube, .note, .audio, .shortcut, .folder: Format.cardRadius
        case .link: card.showsRichLink ? Format.cardBorderedRadius : Format.cardRadius
        case .text: -1
        default: 0
        }
    }

    @State private var lastDrag: CGSize = .zero
    @State private var moveAxis: Axis?
    @State private var didPushMove = false
    @State private var pressBegan = false
    @State private var pressWasSelected = false

    private var pressAndMoveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !pressBegan {
                    pressBegan = true
                    pressWasSelected = app.selectedIDs.contains(card.id)
                    app.menu = nil
                    if !pressWasSelected {
                        app.select([card.id])
                    }
                }

                let moved = hypot(value.translation.width, value.translation.height)
                guard moved >= 6 else { return }

                if !didPushMove {
                    app.pushUndo()
                    didPushMove = true
                    if !app.selectedIDs.contains(card.id) {
                        app.select([card.id])
                    }
                }
                let zoom = max(app.activeLesson?.camera.zoom ?? 1, 0.01)
                var dx = (value.translation.width - lastDrag.width) / zoom
                var dy = (value.translation.height - lastDrag.height) / zoom
                if NSEvent.modifierFlags.contains(.shift) {
                    if moveAxis == nil {
                        moveAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                    }
                    if moveAxis == .horizontal { dy = 0 } else { dx = 0 }
                } else {
                    moveAxis = nil
                }
                lastDrag = value.translation
                app.moveCards(app.selectedIDs, dx: dx, dy: dy)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if didPushMove {
                    app.snapSelected()
                    app.saveNow()
                } else if moved < 6,
                          pressWasSelected,
                          card.kind == .text,
                          app.editingID != card.id
                {
                    // Second click on already-selected text enters edit.
                    app.editingID = card.id
                    app.selectedIDs = [card.id]
                    app.menu = nil
                }
                lastDrag = .zero
                moveAxis = nil
                didPushMove = false
                pressBegan = false
                pressWasSelected = false
            }
    }

    private func open() {
        switch card.kind {
        case .note: app.noteOpenID = card.id
        case .text: app.editingID = card.id
        case .audio: app.audioDetailID = card.id
        case .image: app.lightbox = LightboxItem(src: card.src ?? "", alt: card.alt, bytes: Theme.fileBytes(card.src ?? ""))
        case .link: if let url = card.url { app.openExternal(url) }
        case .shortcut: if let path = card.targetPath, card.missing != true { app.openPath(path) }
        default: break
        }
    }
}

private struct CardClip: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        if radius < 0 {
            content
        } else {
            content.clipShape(CardRoundedRect(radius: radius))
        }
    }
}

private struct CardComposite: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.compositingGroup()
        } else {
            content
        }
    }
}

struct TextCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    let selected: Bool
    private var writing: Bool { app.editingID == card.id }

    var body: some View {
        let ink = Theme.color(card.color)
        Group {
            if writing {
                CanvasTextEditor(
                    html: card.html,
                    plain: card.body ?? card.html,
                    fontSize: card.fontSize ?? 16,
                    ink: NSColor(ink),
                    editing: true,
                    onChange: { html, plain, size in
                        let empty = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        app.updateCard(card.id, persist: false) {
                            $0.html = html
                            $0.body = plain
                            // Keep a usable hit/selection target while empty; otherwise hug content.
                            let minW: Double = empty ? 96 : 36
                            let minH: Double = empty ? 32 : 24
                            $0.width = max(minW, min(GrowingTextView.maxContentWidth, Double(ceil(size.width + 2))))
                            $0.height = max(minH, Double(ceil(size.height + 2)))
                        }
                    },
                    onBeginEditing: {
                        app.editingID = card.id
                        app.selectedIDs = [card.id]
                    },
                    onEndEditing: {
                        app.saveNow()
                    },
                    onBind: { app.activeCanvasTextView = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextRichPreview(html: card.html, plain: card.body ?? card.html, fontSize: card.fontSize ?? 16, ink: ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onAppear { repairNarrowTextIfNeeded() }
    }

    /// Old boxed saves left tall skinny frames — open them up to a readable wrap width.
    private func repairNarrowTextIfNeeded() {
        let plain = card.body ?? ""
        guard plain.count > 40, card.width < 280 else { return }
        let wrap = min(GrowingTextView.maxContentWidth, 480)
        let lines = max(2, Int(ceil(Double(plain.count) / 56)))
        app.updateCard(card.id, persist: false) {
            $0.width = wrap
            $0.height = max(card.height, Double(lines) * 22)
            if let html = $0.html {
                $0.html = CanvasTextEditor.htmlFragment(html)
            }
            if let body = $0.body, body.contains("<!DOCTYPE") || body.contains("<html") {
                $0.body = CanvasTextEditor.plainText(html: body, fallback: plain)
            }
        }
    }
}

private struct TextRichPreview: View {
    let html: String?
    let plain: String?
    let fontSize: CGFloat
    let ink: Color

    var body: some View {
        let attributed = CanvasTextEditor.attributed(
            html: html,
            plain: plain,
            size: fontSize,
            ink: NSColor(ink)
        )
        Text(AttributedString(attributed))
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity((plain?.isEmpty == false || html?.isEmpty == false) ? 1 : 0.35)
    }
}

struct NoteCardView: View {
    let card: Card
    private var bodyText: String {
        CanvasTextEditor.plainText(html: card.html, fallback: card.body)
    }
    private var words: Int { Format.wordCount(bodyText) }

    var body: some View {
        let fill = card.color.map { Theme.color($0) } ?? Theme.surface
        let ink = card.color == nil ? Theme.ink : Theme.onFill(card.color)
        let kicker = ink.opacity(0.55)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kicker)
                Text("Note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(kicker)
            }
            Text(bodyText.isEmpty ? "Empty note" : bodyText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(ink.opacity(bodyText.isEmpty ? 0.4 : 1))
                .lineLimit(3)
                .truncationMode(.tail)
                .lineSpacing(2)
            Spacer(minLength: 0)
            Text("\(words) \(words == 1 ? "word" : "words")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.opacity(0.7))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(ink.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
        .overlay {
            if card.color == nil {
                CardRoundedRect(radius: Format.cardRadius)
                    .strokeBorder(Color(red: 0.90, green: 0.91, blue: 0.92), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct ImageCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card

    var body: some View {
        Color.clear
            .overlay {
                RemoteImage(src: card.src ?? "")
                    .scaledToFill()
            }
            .clipShape(CardRoundedRect(radius: Format.cardRadius))
            .compositingGroup()
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .task(id: card.src) {
                await app.fitImageCard(card.id)
            }
    }
}

struct LinkCardView: View {
    let card: Card
    private var radius: CGFloat { card.showsRichLink ? Format.cardBorderedRadius : Format.cardRadius }

    var body: some View {
        Group {
            if card.showsRichLink {
                richBody
            } else {
                chipBody
            }
        }
        .clipShape(CardRoundedRect(radius: radius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private var chipBody: some View {
        let hex = card.color ?? "#34C759"
        let ink = Theme.onFill(hex)
        return VStack(alignment: .leading, spacing: 4) {
            Text(card.title ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(2)
            Text(card.hostname ?? "")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.8))
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.color(hex))
    }

    private var richBody: some View {
        let fill = card.color.map { Theme.color($0) } ?? Theme.surface
        let ink = card.color == nil ? Theme.ink : Theme.onFill(card.color)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .overlay {
                    RemoteImage(src: card.image ?? "")
                        .scaledToFill()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                Text(card.hostname ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(14)
            .background(fill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
    }
}

struct AudioCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    var playing: Bool { app.playingID == card.id && !app.playbackPaused }
    var selected: Bool { app.selectedIDs.contains(card.id) }
    private var playback: Playback { Playback.shared }
    private var active: Bool { app.playingID == card.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformView(
                peaks: card.peaks ?? DemoLibrary.peaks,
                progress: active ? playback.progress : 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            HStack(alignment: .center, spacing: 10) {
                PlayControl(playing: playing, size: 36) { app.togglePlay(card.id) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title?.isEmpty == false ? card.title! : "Sound")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(timeLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(.black.opacity(0.2), in: Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Theme.color(card.color ?? "#34C759"))
        .overlay {
            if selected {
                CardRoundedRect(radius: Format.cardRadius - 3)
                    .strokeBorder(.white, lineWidth: 2)
                    .padding(3)
                CardRoundedRect(radius: Format.cardRadius)
                    .strokeBorder(.white.opacity(0.95), lineWidth: 2)
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private var timeLabel: String {
        if active {
            return Format.duration(playback.currentSeconds)
        }
        return card.duration?.isEmpty == false ? card.duration! : "0:00"
    }
}

struct WaveformView: View {
    let peaks: [Double]
    var progress: Double = 0
    var onSeek: ((Double) -> Void)?
    var dragToSeek = false

    var body: some View {
        GeometryReader { geo in
            let n = max(peaks.count, 1)
            let gap: CGFloat = 2.4
            let bar = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let playhead = geo.size.width * CGFloat(min(1, max(0, progress)))
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(Array(peaks.enumerated()), id: \.offset) { i, p in
                        let lit = CGFloat(i) / CGFloat(n) * geo.size.width <= playhead
                        Capsule()
                            .fill(.white.opacity(lit && playhead > 1 ? 1 : 0.78))
                            .frame(width: bar, height: max(6, p * min(56, geo.size.height)))
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                if playhead > 1 {
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: min(56, geo.size.height))
                        .offset(x: playhead)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(dragToSeek)
            .contentShape(Rectangle())
            .modifier(WaveformSeekDrag(enabled: dragToSeek) { x in
                seek(x, width: geo.size.width)
            })
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        seek(value.location.x, width: geo.size.width)
                    }
            )
        }
    }

    private func seek(_ x: CGFloat, width: CGFloat) {
        guard width > 0, NSEvent.pressedMouseButtons != 2 else { return }
        onSeek?(min(1, max(0, Double(x / width))))
    }
}

private struct WaveformSeekDrag: ViewModifier {
    var enabled: Bool
    var onSeek: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard NSEvent.pressedMouseButtons == 1 else { return }
                        onSeek(value.location.x)
                    }
            )
        } else {
            content
        }
    }
}

struct VideoCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    var playing: Bool { app.playingID == card.id }

    var body: some View {
        ZStack {
            if playing, let player = Playback.shared.videoPlayer {
                VideoPlayer(player: player)
            } else {
                Color.clear
                    .overlay {
                        RemoteImage(src: card.poster ?? card.src ?? "")
                            .scaledToFill()
                    }
            }
            if !playing {
                PlayControl(playing: false, large: true) { app.togglePlay(card.id) }
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(CardRoundedRect(radius: Format.cardRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

struct ShortcutCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card

    var body: some View {
        let missing = card.missing == true || missingOnDisk
        VStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 58, height: 58)
            Text(card.title ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(missing ? Theme.muted : Theme.onFill(card.color ?? "#C6FF3A"))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if missing {
                Text("Not found")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(missing ? Color(red: 0.91, green: 0.91, blue: 0.93) : Theme.color(card.color ?? "#C6FF3A"))
        .overlay {
            CardRoundedRect(radius: Format.cardRadius)
                .strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
        }
        .task { await refreshMissing() }
    }

    private var missingOnDisk: Bool {
        guard let path = card.targetPath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    private var icon: NSImage {
        if let path = card.targetPath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(forFileType: "public.folder")
    }

    private func refreshMissing() async {
        guard let path = card.targetPath else { return }
        let ok = FileManager.default.fileExists(atPath: path)
        if ok == !(card.missing ?? false) { return }
        app.updateCard(card.id) { $0.missing = !ok }
    }
}

struct DrawCardView: View {
    let card: Card
    var body: some View {
        Canvas { context, _ in
            guard let pts = card.points, let first = pts.first else { return }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            context.stroke(path, with: .color(Theme.color(card.stroke ?? "#111318")), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}

struct YouTubeCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    var playing: Bool { app.playingID == card.id }

    var body: some View {
        ZStack {
            if playing, let id = card.videoId,
               let url = URL(string: "https://www.youtube.com/embed/\(id)?autoplay=1&rel=0&modestbranding=1")
            {
                WebEmbed(url: url)
            } else {
                Color.black
                    .overlay {
                        RemoteImage(src: "https://img.youtube.com/vi/\(card.videoId ?? "")/hqdefault.jpg")
                            .scaledToFill()
                    }
                PlayControl(playing: false, large: true) { app.setPlaying(card.id) }
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(CardRoundedRect(radius: Format.cardRadius))
        .compositingGroup()
    }
}

struct PlayControl: View {
    var playing: Bool
    var large = false
    var size: CGFloat?
    var action: () -> Void

    private var side: CGFloat { size ?? (large ? 44 : 36) }

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: side > 36 ? 15 : 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .offset(x: playing ? 0 : 1)
                .frame(width: side, height: side)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct RemoteImage: View {
    let src: String
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if src.hasPrefix("http"), let url = URL(string: src) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
                    default:
                        GhostPlaceholder()
                    }
                }
            } else if let url = URL(string: src), url.isFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if !src.isEmpty, let image = NSImage(contentsOfFile: src) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                GhostPlaceholder()
            }
        }
    }

    func resizable() -> RemoteImage { self }
    func scaledToFit() -> RemoteImage { RemoteImage(src: src, contentMode: .fit) }
    func scaledToFill() -> RemoteImage { RemoteImage(src: src, contentMode: .fill) }
}

struct GhostPlaceholder: View {
    @State private var pulse = false
    var body: some View {
        CardRoundedRect(radius: 12)
            .fill(Color(white: 0.88))
            .overlay {
                CardRoundedRect(radius: 12)
                    .fill(Color.white.opacity(pulse ? 0.45 : 0.12))
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

struct WebEmbed: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }
}
