import AppKit
import Charts
import SwiftUI

struct AnalyzeView: View {
    @Bindable var store: AnalyzeStore
    @State private var tab: Tab = .folders
    @State private var confirmTrash = false
    @State private var pendingTrash: [AnalyzeEntry] = []

    enum Tab: String, CaseIterable, Identifiable {
        case folders = "İçerik"
        case largeFiles = "Büyük Dosyalar"
        var id: String { rawValue }
    }

    private struct QuickLocation: Identifiable {
        let title: String
        let symbol: String
        let path: String?
        var id: String { path ?? "overview" }
    }

    private var quickLocations: [QuickLocation] {
        let home = Engine.homeDirectory
        return [
            QuickLocation(title: "Ana Klasör", symbol: "house.fill", path: home),
            QuickLocation(title: "İndirilenler", symbol: "arrow.down.circle.fill", path: home + "/Downloads"),
            QuickLocation(title: "Belgeler", symbol: "doc.fill", path: home + "/Documents"),
            QuickLocation(title: "Kitaplık", symbol: "books.vertical.fill", path: home + "/Library"),
            QuickLocation(title: "Uygulamalar", symbol: "square.grid.2x2.fill", path: "/Applications"),
            QuickLocation(title: "Tüm Disk", symbol: "internaldrive.fill", path: nil),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .analyze) {
                Menu {
                    ForEach(quickLocations) { location in
                        Button {
                            store.open(.init(path: location.path))
                        } label: {
                            Label(location.title, systemImage: location.symbol)
                        }
                    }
                    Divider()
                    Button("Klasör Seç…") { chooseFolder() }
                } label: {
                    Label("Konum", systemImage: "folder")
                }
                .fixedSize()
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)

            if store.location == nil {
                landing
            } else {
                navigationBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                if let error = store.errorMessage {
                    ErrorBanner(message: error) { store.refresh() }
                        .padding(.horizontal, 24)
                }
                if store.isScanning {
                    WorkingPanel(title: "\(store.location?.title ?? "") taranıyor…",
                                 detail: store.location?.path ?? "Tüm disk genel bakışı",
                                 tint: Page.analyze.tint, startedAt: store.startedAt) {
                        store.cancel()
                    }
                } else if let result = store.result {
                    resultView(result)
                } else {
                    Spacer()
                }
            }
            if !store.selection.isEmpty {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.selection.isEmpty)
        .confirmationDialog("Seçili öğeler Çöp Sepeti'ne taşınsın mı?", isPresented: $confirmTrash) {
            Button("Çöpe Taşı", role: .destructive) {
                store.moveToTrash(pendingTrash.map(\.path))
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(trashMessage)
        }
        .alert("Çöp Sepeti", isPresented: Binding(
            get: { store.lastTrashReport.map { $0.failed > 0 } ?? false },
            set: { if !$0 { store.lastTrashReport = nil } }
        )) {
            Button("Tamam") { store.lastTrashReport = nil }
        } message: {
            Text(trashReportMessage)
        }
    }

    private var trashMessage: String {
        let total = pendingTrash.reduce(Int64(0)) { $0 + $1.size }
        let names = pendingTrash.prefix(4).map(\.name).joined(separator: ", ")
        let more = pendingTrash.count > 4 ? " ve \(pendingTrash.count - 4) öğe daha" : ""
        return "\(names)\(more) (\(TextUtils.formatBytes(total))) Çöp Sepeti'ne taşınacak. Sistem ve korumalı yollar motor tarafından reddedilir; işlem Mole geçmişine kaydedilir."
    }

    private var trashReportMessage: String {
        guard let report = store.lastTrashReport else { return "" }
        let failures = report.results.filter { !$0.ok }.prefix(5).map { "• \(TextUtils.abbreviatePath($0.path)): \($0.error ?? "")" }
        return "\(report.moved) öğe taşındı, \(report.failed) öğe atlandı.\n" + failures.joined(separator: "\n")
    }

    // MARK: Landing

    private var landing: some View {
        HeroPrompt(
            page: .analyze,
            title: "Nereyi incelemek istersiniz?",
            message: "Bir konum seçin; klasörler boyuta göre sıralanır, içlerine girebilir ve gereksiz büyük dosyaları güvenle Çöp Sepeti'ne taşıyabilirsiniz."
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(quickLocations) { location in
                        Button {
                            store.open(.init(path: location.path))
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: location.symbol)
                                    .font(.system(size: 20))
                                    .foregroundStyle(Page.analyze.tint)
                                Text(location.title)
                                    .font(.caption.weight(.medium))
                            }
                            .frame(width: 92, height: 64)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Başka bir klasör seç…") { chooseFolder() }
                    .buttonStyle(GradientButtonStyle(tint: Page.analyze.tint))
            }
        }
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!store.canGoBack || store.isScanning)
            .help("Geri")

            breadcrumb
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField("Süz", text: $store.filterText)
                    .textFieldStyle(.plain)
                    .frame(width: 130)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isScanning)
            .help("Yeniden tara")
        }
    }

    private var breadcrumb: some View {
        let components = breadcrumbComponents
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                    }
                    Button(item.title) {
                        if index < components.count - 1 {
                            store.open(.init(path: item.path))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(index == components.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == components.count - 1 ? Color.primary : Color.secondary)
                }
            }
        }
    }

    private var breadcrumbComponents: [(title: String, path: String?)] {
        guard let path = store.location?.path else { return [("Tüm Disk", nil)] }
        var items: [(title: String, path: String?)] = []
        let home = Engine.homeDirectory
        var base = ""
        var rest = path
        if path == home || path.hasPrefix(home + "/") {
            items.append(("Ana Klasör", home))
            base = home
            rest = String(path.dropFirst(home.count))
        } else {
            items.append(("Disk", nil))
        }
        for part in rest.split(separator: "/") {
            base += "/" + part
            items.append((String(part), base))
        }
        return items
    }

    // MARK: Result

    private func resultView(_ result: AnalyzeResult) -> some View {
        VStack(spacing: 12) {
            summaryCard(result)
                .padding(.horizontal, 24)
            if !(result.largeFiles ?? []).isEmpty {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    if tab == .largeFiles, let files = result.largeFiles, !files.isEmpty {
                        let maxSize = max(files.map(\.size).max() ?? 1, 1)
                        ForEach(files.sorted { $0.size > $1.size }) { file in
                            EntryRow(entry: AnalyzeEntry(name: file.name, path: file.path, size: file.size, isDir: false),
                                     fraction: Double(file.size) / Double(maxSize),
                                     share: share(file.size, of: result),
                                     store: store,
                                     requestTrash: requestTrash)
                        }
                    } else {
                        ForEach(store.entries) { entry in
                            EntryRow(entry: entry,
                                     fraction: Double(entry.size) / Double(store.largestSize),
                                     share: share(entry.size, of: result),
                                     store: store,
                                     requestTrash: requestTrash)
                        }
                        if store.entries.isEmpty {
                            Text(store.filterText.isEmpty ? "Bu klasör boş." : "Süzgeçle eşleşen öğe yok.")
                                .foregroundStyle(.secondary)
                                .padding(30)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private func share(_ size: Int64, of result: AnalyzeResult) -> Double {
        let total = result.totalSize ?? (result.entries ?? []).reduce(0) { $0 + $1.size }
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    private func summaryCard(_ result: AnalyzeResult) -> some View {
        let top = Array((result.entries ?? []).sorted { $0.size > $1.size }.prefix(6))
        let total = result.totalSize ?? (result.entries ?? []).reduce(0) { $0 + $1.size }
        let rest = max(total - top.reduce(0) { $0 + $1.size }, 0)
        let palette: [Color] = [Theme.orange, Theme.pink, Theme.purple, Theme.blue, Theme.teal, Theme.green, Theme.gray]
        var slices: [(name: String, size: Int64, color: Color)] = top.enumerated().map { index, entry in
            (entry.name, entry.size, palette[index % palette.count])
        }
        if rest > 0 { slices.append(("Diğer", rest, Theme.gray.opacity(0.5))) }

        return Card(padding: 16) {
            HStack(spacing: 22) {
                ZStack {
                    Chart(Array(slices.enumerated()), id: \.offset) { _, slice in
                        SectorMark(angle: .value("Boyut", Double(slice.size)), innerRadius: .ratio(0.62), angularInset: 1.2)
                            .foregroundStyle(slice.color)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    VStack(spacing: 0) {
                        Text(TextUtils.formatBytes(total))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        if let files = result.totalFiles, files > 0 {
                            Text("\(files) dosya")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 138, height: 138)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.color).frame(width: 9, height: 9)
                            Text(slice.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(TextUtils.formatBytes(slice.size))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: 360)
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if let path = result.overview == true ? nil : Optional(result.path) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Label("Finder'da Aç", systemImage: "folder")
                        }
                    }
                    let cleanable = (result.entries ?? []).filter { $0.cleanable == true }
                    if !cleanable.isEmpty {
                        Label("\(cleanable.count) temizlenebilir öğe", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(Theme.teal)
                    }
                }
            }
        }
    }

    // MARK: Selection

    private var selectionBar: some View {
        let selected = store.selectedEntries
        let total = selected.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Page.analyze.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selected.count) öğe seçildi")
                    .font(.callout.weight(.semibold))
                Text(TextUtils.formatBytes(total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Seçimi Temizle") { store.selection.removeAll() }
                .buttonStyle(.borderless)
            Button {
                requestTrash(selected)
            } label: {
                if store.isTrashing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Çöpe Taşı", systemImage: "trash")
                }
            }
            .buttonStyle(GradientButtonStyle(tint: Theme.red))
            .disabled(store.isTrashing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func requestTrash(_ entries: [AnalyzeEntry]) {
        guard !entries.isEmpty else { return }
        pendingTrash = entries
        confirmTrash = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: Engine.homeDirectory)
        panel.prompt = "Analiz Et"
        if panel.runModal() == .OK, let url = panel.url {
            store.openDirectory(url.path)
        }
    }
}

private struct EntryRow: View {
    let entry: AnalyzeEntry
    let fraction: Double
    let share: Double
    let store: AnalyzeStore
    let requestTrash: ([AnalyzeEntry]) -> Void
    @State private var hovering = false

    private var isSelected: Bool { store.selection.contains(entry.path) }
    private var isDirectory: Bool { entry.isDir == true }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isSelected { store.selection.remove(entry.path) } else { store.selection.insert(entry.path) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Page.analyze.tint : Color.secondary.opacity(hovering ? 0.8 : 0.35))
            }
            .buttonStyle(.plain)

            FileIcon(path: entry.path, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.cleanable == true {
                        Badge(text: "Temizlenebilir", tint: Theme.teal)
                    }
                    if entry.insight == true {
                        Badge(text: "Öneri", tint: Theme.purple)
                    }
                }
                CapsuleBar(fraction: fraction, tint: barTint, height: 5)
            }
            Text(String(format: "%.1f%%", share * 100))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Text(TextUtils.formatBytes(entry.size))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isDirectory ? Color.secondary : Color.clear)
                .frame(width: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Page.analyze.tint.opacity(0.10) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .contextMenu {
            if isDirectory {
                Button("İçine Gir") { store.openDirectory(entry.path) }
            }
            Button("Aç") { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
            Button("Finder'da Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            Button("Yolu Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
            Divider()
            Button("Çöpe Taşı…", role: .destructive) { requestTrash([entry]) }
        }
        .help(entry.path)
    }

    private var barTint: Color {
        if entry.cleanable == true { return Theme.teal }
        if fraction > 0.6 { return Theme.red }
        if fraction > 0.3 { return Theme.orange }
        return Page.analyze.tint.opacity(0.75)
    }

    private func open() {
        if isDirectory {
            store.openDirectory(entry.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
    }
}
