import AppKit
import SwiftUI

/// A collapsible log of everything the engine printed during previews and
/// scans, docked at the bottom of the window.
struct ConsolePanel: View {
    @Bindable var console: ConsoleLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { console.isVisible.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: console.isVisible ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                        Image(systemName: "text.alignleft")
                        Text("Konsol")
                            .fontWeight(.semibold)
                        if let last = console.lines.last, !console.isVisible {
                            Text(last.text)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if console.isVisible {
                    Button {
                        let text = console.lines.map { "[\($0.source)] \($0.text)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Konsolu kopyala")
                    Button {
                        console.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Konsolu temizle")
                }
                Text("\(console.lines.count) satır")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.bar)

            if console.isVisible {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(console.lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(Self.timeFormatter.string(from: line.date))
                                        .foregroundStyle(.tertiary)
                                    Text(line.source)
                                        .foregroundStyle(Theme.teal)
                                        .frame(width: 64, alignment: .leading)
                                    Text(line.text)
                                        .textSelection(.enabled)
                                }
                                .id(line.id)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 190)
                    .background(Theme.windowBackground)
                    .onChange(of: console.lines.count) { _, _ in
                        if let last = console.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = console.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
