import AppKit
import SwiftUI

/// A "preview, then run" page for optimize, purge, installer and slim. The
/// preview runs the engine's dry run without a terminal; the real run opens
/// the terminal sheet so the engine's own selectors and prompts are used.
struct ToolPageView: View {
    @Environment(AppModel.self) private var model
    let store: ToolStore
    @State private var confirmRun = false

    private var spec: ToolSpec { store.spec }
    private var page: Page { spec.page }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(page: page) {
                if !spec.extraActions.isEmpty {
                    Menu {
                        ForEach(Array(spec.extraActions.enumerated()), id: \.offset) { _, action in
                            Button(action.title) {
                                model.runInTerminal(title: action.title.replacingOccurrences(of: "…", with: ""),
                                                    subtitle: page.title, arguments: action.arguments, tint: page.tint)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
            .padding(24)

            if store.isRunning || store.finished {
                previewPanel
            } else {
                HeroPrompt(page: page, title: spec.heroTitle, message: spec.heroMessage, bullets: spec.bullets) {
                    Button {
                        store.preview()
                    } label: {
                        Label("Önizle", systemImage: "eye")
                    }
                    .keyboardShortcut(.defaultAction)
                    Button {
                        confirmRun = true
                    } label: {
                        Label(spec.runTitle, systemImage: "play.fill")
                    }
                    .buttonStyle(GradientButtonStyle(tint: page.tint))
                }
            }
        }
        .confirmationDialog("\(spec.runTitle)?", isPresented: $confirmRun) {
            Button("Başlat") { run() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(spec.confirmMessage)
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if store.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Önizleme hazırlanıyor…")
                        .font(.headline)
                    if let started = store.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text("\(Int(context.date.timeIntervalSince(started))) sn")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    Image(systemName: store.exitStatus == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.exitStatus == 0 ? Theme.green : Theme.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.exitStatus == 0 ? "Önizleme hazır, hiçbir şey değiştirilmedi" : "Önizleme tamamlanamadı")
                            .font(.headline)
                        if let last = store.lastRunAt {
                            Text(last.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if store.isRunning {
                    Button("Vazgeç") { store.cancel() }
                } else {
                    Button {
                        store.preview()
                    } label: {
                        Label("Yeniden Önizle", systemImage: "arrow.clockwise")
                    }
                    Button {
                        confirmRun = true
                    } label: {
                        Label(spec.runTitle, systemImage: "play.fill")
                    }
                    .buttonStyle(GradientButtonStyle(tint: page.tint))
                }
            }
            .padding(.horizontal, 24)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(store.output.enumerated()), id: \.offset) { index, line in
                            LogLine(text: line, tint: page.tint)
                                .id(index)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline)
                )
                .onChange(of: store.output.count) { _, count in
                    if store.isRunning, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func run() {
        model.runInTerminal(
            title: spec.runTitle,
            subtitle: page.title,
            arguments: [spec.command],
            tint: page.tint
        ) { _ in
            if store.finished { store.preview() }
        }
    }
}

/// One engine output line, tinted by the engine's status glyphs.
struct LogLine: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let indent = text.prefix { $0 == " " }.count
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let glyph = glyph(for: trimmed) {
                Image(systemName: glyph.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(glyph.color)
                    .frame(width: 14)
                Text(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    .textSelection(.enabled)
            } else if isHeading(trimmed) {
                Text(trimmed)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 6)
            } else {
                Text(trimmed)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(min(indent, 8)) * 6)
    }

    private func glyph(for line: String) -> (symbol: String, color: Color)? {
        guard let first = line.first else { return nil }
        switch first {
        case "✓": return ("checkmark.circle.fill", Theme.green)
        case "☻": return ("xmark.octagon.fill", Theme.red)
        case "◎": return ("exclamationmark.circle.fill", Theme.orange)
        case "→": return ("arrow.right.circle", Theme.blue)
        case "•": return ("circle.fill", Color.secondary)
        case "↳": return ("arrow.turn.down.right", Color.secondary)
        case "➤": return ("chevron.right.circle.fill", tint)
        case "⊙": return ("eye.circle", Theme.purple)
        case "ℹ": return ("info.circle.fill", Theme.blue)
        case "⚙": return ("gearshape.fill", Theme.gray)
        default: return nil
        }
    }

    private func isHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count < 60, text.first != " " else { return false }
        guard let first = line.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return !line.contains(":") && !line.hasSuffix(".") && line.first?.isUppercase == true
    }
}
