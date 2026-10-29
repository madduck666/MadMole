import AppKit
import SwiftUI

struct HistoryView: View {
    let store: HistoryStore
    @State private var tab: Tab = .sessions
    @State private var query = ""

    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Oturumlar"
        case deletions = "Silinen Öğeler"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(page: .history) {
                Button {
                    NSWorkspace.shared.open(Engine.logDirectory)
                } label: {
                    Label("Log Klasörü", systemImage: "folder")
                }
                .disabled(!FileManager.default.fileExists(atPath: Engine.logDirectory.path))
                Button {
                    store.load()
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
            .padding(24)

            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                if tab == .deletions {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Yol ara", text: $query).textFieldStyle(.plain).frame(width: 180)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if let error = store.errorMessage {
                ErrorBanner(message: error) { store.load() }
                    .padding(.horizontal, 24)
            }

            if store.isLoading && store.log == nil {
                WorkingPanel(title: "Geçmiş okunuyor…", tint: Page.history.tint)
            } else if let log = store.log {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        switch tab {
                        case .sessions:
                            let sessions = log.sessions ?? []
                            if sessions.isEmpty { empty("Henüz kayıtlı bir işlem yok.") }
                            ForEach(sessions) { SessionRow(session: $0) }
                        case .deletions:
                            let rows = (log.deletions ?? []).filter {
                                query.isEmpty || ($0.path ?? "").localizedCaseInsensitiveContains(query)
                            }
                            if rows.isEmpty { empty("Silinen öğe kaydı yok.") }
                            ForEach(rows) { DeletionRow(row: $0) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            } else {
                Spacer()
            }
        }
        .onAppear { store.load() }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(40)
    }
}

private struct SessionRow: View {
    let session: HistoryLog.Session

    var body: some View {
        let style = Self.style(for: session.command ?? "")
        HStack(spacing: 12) {
            IconTile(symbol: style.symbol, tint: style.tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(style.title)
                        .font(.system(size: 14, weight: .semibold))
                    if (session.command ?? "").hasSuffix("dry-run") {
                        Badge(text: "Önizleme", tint: Theme.blue)
                    }
                    if let failed = session.failedTasks, failed > 0 {
                        Badge(text: "\(failed) hata", tint: Theme.red)
                    }
                }
                Text(session.startedAt ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let actions = session.actions {
                HStack(spacing: 10) {
                    count(actions.removed, "trash", "silindi")
                    count(actions.trashed, "trash.circle", "Çöp'e")
                    count(actions.rebuilt, "arrow.triangle.2.circlepath", "yenilendi")
                    count(actions.skipped, "forward", "atlandı")
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.size?.isEmpty == false ? session.size! : "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let items = session.items {
                    Text("\(items) öğe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder
    private func count(_ value: Int?, _ symbol: String, _ label: String) -> some View {
        if let value, value > 0 {
            Label("\(value)", systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("\(value) \(label)")
        }
    }

    static func style(for command: String) -> (title: String, symbol: String, tint: Color) {
        let base = command.components(separatedBy: "-dry-run").first ?? command
        switch base {
        case "clean": return (Page.clean.title, Page.clean.symbol, Page.clean.tint)
        case "uninstall": return (Page.uninstall.title, Page.uninstall.symbol, Page.uninstall.tint)
        case "optimize": return (Page.optimize.title, Page.optimize.symbol, Page.optimize.tint)
        case "purge": return (Page.purge.title, Page.purge.symbol, Page.purge.tint)
        case "installer": return (Page.installer.title, Page.installer.symbol, Page.installer.tint)
        case "slim": return (Page.slim.title, Page.slim.symbol, Page.slim.tint)
        case "analyze": return (Page.analyze.title, Page.analyze.symbol, Page.analyze.tint)
        case "touchid": return ("Touch ID", "touchid", Theme.pink)
        case "update": return ("Güncelleme", "arrow.down.circle.fill", Theme.blue)
        default: return (command.isEmpty ? "İşlem" : command, "gearshape.fill", Theme.gray)
        }
    }
}

private struct DeletionRow: View {
    let row: HistoryLog.Deletion

    var body: some View {
        let ok = (row.status ?? "") == "ok"
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Theme.green : Theme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(TextUtils.abbreviatePath(row.path ?? ""))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(row.timestamp ?? "")
                    if let mode = row.mode { Badge(text: mode == "trash" ? "Çöp Sepeti" : mode, tint: Theme.blue) }
                    if !ok, let status = row.status { Badge(text: status, tint: Theme.orange) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let kb = row.sizeKb {
                Text(TextUtils.formatBytes(kb * 1024))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.cardBackground))
    }
}
