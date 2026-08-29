import SwiftUI

/// "Organize with AI" popup — the user names a clustering criterion in their own words
/// (theme, color, subject, or anything else) and `AppModel.arrangeWithAI(criterion:)`
/// clusters the current selection/group accordingly. Same dimmer+card chrome as
/// `LinkPrompt`/`ProviderSettingsPanel`.
struct ArrangeAIPrompt: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var criterion: String = ""
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private let presets: [(String, String)] = [
        ("Theme", "group by topic/theme"),
        ("Color", "group by dominant color"),
        ("Subject", "group by subject area"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(scheme == .dark ? 0.45 : 0.28)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 14) {
                header
                presetRow
                field
                if let error = app.aiArrangeError {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.extractStroke)
                }
                submitRow
            }
            .padding(20)
            .frame(width: 360)
            .background(Theme.cardSurface(scheme).opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline(scheme)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 20, y: 8)
        }
        .onAppear {
            criterion = app.aiArrangeCriterion
            focused = true
        }
        .onExitCommand { close() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(icon: .askAI, size: 12)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Organize with AI")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryInk(scheme))
            Spacer()
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.0) { title, value in
                Button {
                    AppSounds.playTap()
                    criterion = value
                    focused = true
                } label: {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(criterion == value ? Color.white : Theme.secondaryInk(scheme))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            criterion == value ? Theme.selectFill(scheme) : Theme.elevHover(scheme),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    /// Multi-line so a pasted long criterion (or a whole paragraph of context) stays fully
    /// visible and scrollable instead of scrolling out of view in a single-line `TextField`.
    private var field: some View {
        TextEditor(text: $criterion)
            .font(.system(size: 13))
            .foregroundStyle(Theme.primaryInk(scheme))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 34, maxHeight: 120)
            .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focused($focused)
            .disabled(app.aiArrangeInFlight)
            .overlay(alignment: .topLeading) {
                if criterion.isEmpty {
                    Text("Group by…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    private var submitRow: some View {
        HStack {
            Spacer()
            Button("Cancel") { close() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryInk(scheme))
            Button {
                submit()
            } label: {
                HStack(spacing: 6) {
                    if app.aiArrangeInFlight {
                        PulsingDot()
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(app.aiArrangeInFlight ? "Organizing…" : "Organize")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(canSubmit ? Theme.ink : Theme.ink.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        !app.aiArrangeInFlight && !criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else {
            AppSounds.play(.disabled)
            return
        }
        AppSounds.playTap()
        let value = criterion
        task = Task { await app.arrangeWithAI(criterion: value) }
    }

    private func close() {
        task?.cancel()
        app.aiArrangePromptOpen = false
    }
}

/// Three-dot pulsing indicator matching the rest of the app's non-native loading treatment.
private struct PulsingDot: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
