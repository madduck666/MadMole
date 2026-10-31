import AppKit
import SwiftUI

struct CleanView: View {
    @Environment(AppModel.self) private var model
    let store: CleanStore
    @State private var expanded: Set<String> = []
    @State private var confirmClean = false
    @State private var confirmScanWithoutAccess = false
    @State private var copiedPerf = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(page: .clean) {
                if case .loaded = store.phase {
                    Button {
                        startScan()
                    } label: {
                        Label("Yeniden Tara", systemImage: "arrow.clockwise")
                    }
                }
                Menu {
                    Button("Ayrıntılı tarama (hız ölçümü)") {
                        store.scan(verbose: true)
                    }
                    .disabled(store.isScanning)
                    Divider()
                    Button("Korunan yolları düzenle…") {
                        model.runInTerminal(title: "Korunan Yollar", subtitle: "Temizlikte asla dokunulmayacak yolları seçin",
                                            arguments: ["clean", "--whitelist"], tint: Page.clean.tint)
                    }
                    Button("Önizleme listesini Finder'da göster") {
                        NSWorkspace.shared.activateFileViewerSelecting([Engine.cleanPreviewFile])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: Engine.cleanPreviewFile.path))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            .padding(24)

            switch store.phase {
            case .idle:
                HeroPrompt(
                    page: .clean,
                    title: "Mac'inizi tarayın",
                    message: "Önce hiçbir şeyi silmeden bir önizleme yapılır. Ne kadar yer açılacağını ve nelerin silineceğini gördükten sonra karar verirsiniz.",
                    bullets: [
                        "Uygulama ve tarayıcı önbellekleri, loglar, geçici dosyalar",
                        "Geliştirici araçlarının yeniden oluşturulabilir önbellekleri",
                        "Kaldırılmış uygulamalardan kalan artıklar",
                        "Korunan yollar ve sistem dosyaları asla silinmez",
                    ]
                ) {
                    Button {
                        startScan()
                    } label: {
                        Label("Taramayı Başlat", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(GradientButtonStyle(tint: Page.clean.tint))
                    .keyboardShortcut(.defaultAction)
                }
            case .scanning:
                WorkingPanel(title: "Temizlenebilir dosyalar aranıyor…", detail: store.lastLine,
                             tint: Page.clean.tint, startedAt: store.startedAt,
                             lastActivity: store.lastActivity,
                             note: "İlk tarama, uygulama ve geliştirici aracı sayısına göre birkaç dakika sürebilir.",
                             onRestartVerbose: {
                                 store.cancel()
                                 store.scan(verbose: true)
                             }) {
                    store.cancel()
                }
            case let .failed(message):
                VStack(spacing: 16) {
                    ErrorBanner(message: message) { store.scan() }
                    Spacer()
                }
                .padding(.horizontal, 24)
            case .loaded:
                if let preview = store.preview {
                    results(preview)
                }
            }
        }
        .confirmationDialog("Tam Disk Erişimi kapalı", isPresented: $confirmScanWithoutAccess) {
            Button("Önce İzin Ver") { PrivacyPane.open(.fullDiskAccess) }
            Button("Yine de Tara") { store.scan() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("İzin olmadan macOS, başka uygulamaların klasörleri için tek tek soru sorar ve tarama her soruda cevabınızı bekler; bu yüzden uzun sürebilir ya da takılmış gibi görünebilir. Güncellemeden sonra izin düştüyse MadMole'u listeden çıkarıp yeniden ekleyin.")
        }
        .confirmationDialog("Temizlik başlatılsın mı?", isPresented: $confirmClean) {
            Button("Temizliği Başlat") { startClean() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Temizlik terminal penceresinde çalışır. Sistem önbellekleri için yönetici izni isteyebilir; isterseniz Boşluk tuşuyla bu adımı atlayabilirsiniz.")
        }
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ preview: CleanPreview) -> some View {
        if preview.sections.isEmpty {
            HeroPrompt(page: .clean, title: "Her şey tertemiz", message: "Şu an temizlenecek bir şey bulunamadı. Daha sonra tekrar tarayabilirsiniz.") {
                Button("Yeniden Tara") { startScan() }
            }
        } else {
            VStack(spacing: 0) {
                summary(preview)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                if !store.perfReport.isEmpty {
                    perfCard
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(preview.sections) { section in
                            sectionCard(section, maxBytes: preview.sections.map(\.countedBytes).max() ?? 1)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func summary(_ preview: CleanPreview) -> some View {
        Card(padding: 18) {
            HStack(spacing: 22) {
                ZStack {
                    Circle().fill(Page.clean.tint.opacity(0.14)).frame(width: 84, height: 84)
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Page.clean.tint)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Açılabilecek alan")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(TextUtils.formatBytes(preview.totalBytes) + (preview.hasUnknownSizes ? "+" : ""))
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [Page.clean.tint, Theme.blue], startPoint: .leading, endPoint: .trailing))
                    Text("\(preview.sections.count) kategori · \(preview.totalItems) öğe"
                        + (store.lastScan.map { " · " + $0.formatted(date: .omitted, time: .shortened) + " taraması" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !store.systemPreviewIncluded {
                        Label("Sistem önbellekleri yönetici izni gerektirdiği için önizlemeye dahil değil; temizlik sırasında sorulur.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        confirmClean = true
                    } label: {
                        Label("Temizle", systemImage: "trash")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(GradientButtonStyle(tint: Page.clean.tint))
                    .keyboardShortcut(.defaultAction)
                    Button(expanded.count == preview.sections.count ? "Tümünü daralt" : "Tümünü genişlet") {
                        withAnimation {
                            if expanded.count == preview.sections.count {
                                expanded.removeAll()
                            } else {
                                expanded = Set(preview.sections.map(\.id))
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private var perfCard: some View {
        Card(title: "Hız ölçümü: en yavaş adımlar", symbol: "stopwatch", tint: Theme.orange) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.perfReport.prefix(8)) { entry in
                    HStack {
                        Text(entry.label)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1f sn", entry.seconds))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
            HStack {
                Text(store.lastScanDuration.map { "Toplam \(Int($0)) sn" } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.perfReportText, forType: .string)
                    copiedPerf = true
                } label: {
                    Label(copiedPerf ? "Kopyalandı" : "Raporu Kopyala", systemImage: copiedPerf ? "checkmark" : "doc.on.doc")
                }
            }
        }
    }

    private func sectionCard(_ section: CleanPreview.Section, maxBytes: Int64) -> some View {
        let isOpen = expanded.contains(section.id)
        let style = CleanSectionStyle.style(for: section.name)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { expanded.remove(section.id) } else { expanded.insert(section.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: style.symbol, tint: style.tint, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(CleanSectionStyle.title(for: section.name))
                            .font(.system(size: 14, weight: .semibold))
                            .help(section.name)
                        CapsuleBar(fraction: Double(section.countedBytes) / Double(max(maxBytes, 1)), tint: style.tint, height: 5)
                            .frame(maxWidth: 260)
                    }
                    Spacer()
                    Text("\(section.countedItems) öğe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(TextUtils.formatBytes(section.countedBytes))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.items) { item in
                        CleanItemRow(item: item)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline)
        )
    }

    private func startScan() {
        if Permissions.fullDiskAccess == .denied {
            confirmScanWithoutAccess = true
        } else {
            store.scan()
        }
    }

    private func startClean() {
        model.runInTerminal(
            title: "Temizlik",
            subtitle: "Mole önbellekleri, logları ve geçici dosyaları temizliyor",
            arguments: ["clean"],
            tint: Page.clean.tint
        ) { _ in
            store.scan()
        }
    }
}

private struct CleanItemRow: View {
    let item: CleanPreview.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(path: item.path, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(TextUtils.abbreviatePath(item.path))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                if let parent = item.coveredBy {
                    Text("Üst klasörde sayıldı: \(TextUtils.abbreviatePath(parent))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if item.itemCount > 1 {
                Text("\(item.itemCount) öğe")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if hovering {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Finder'da göster")
            }
            Text(item.sizeBytes.map { TextUtils.formatBytes($0) } ?? "bilinmiyor")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.coveredBy == nil ? Color.primary : Color.secondary)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// An icon and tint for a cleanup section, chosen by keywords in its name.
struct CleanSectionStyle {
    let symbol: String
    let tint: Color

    /// Turkish titles for the engine's section names; unknown names pass through.
    static func title(for name: String) -> String {
        let titles: [String: String] = [
            "System": "Sistem",
            "User essentials": "Kullanıcı önbellekleri ve loglar",
            "App caches": "Uygulama önbellekleri",
            "App leftovers": "Kaldırılmış uygulama artıkları",
            "Apple Silicon updates": "Apple Silicon güncellemeleri",
            "Application Support": "Uygulama destek dosyaları",
            "Apps & utilities": "Uygulamalar ve araçlar",
            "Browsers": "Tarayıcılar",
            "Cloud & Office": "Bulut ve Office",
            "Developer tools": "Geliştirici araçları",
            "Device backups & firmware": "Aygıt yedekleri ve yazılımları",
            "External volume": "Harici disk",
            "Large files": "Büyük dosyalar",
            "Project artifacts": "Proje artıkları",
            "Time Machine": "Time Machine",
            "Virtualization": "Sanallaştırma",
        ]
        return titles[name] ?? name
    }

    static func style(for name: String) -> CleanSectionStyle {
        let n = name.lowercased()
        let table: [([String], String, Color)] = [
            (["browser", "safari", "chrome", "firefox", "edge"], "globe", Theme.blue),
            (["xcode", "simulator", "developer", "npm", "node", "python", "go ", "rust", "cargo", "gradle", "docker", "homebrew", "brew", "dev"], "hammer.fill", Theme.purple),
            (["log"], "doc.text.fill", Theme.gray),
            (["trash"], "trash.fill", Theme.red),
            (["system"], "gearshape.2.fill", Theme.indigo),
            (["app", "leftover", "orphan"], "app.badge", Theme.pink),
            (["temp", "tmp"], "clock.badge.xmark", Theme.orange),
            (["cache"], "archivebox.fill", Theme.teal),
            (["download", "installer"], "arrow.down.circle.fill", Theme.green),
            (["mail", "message"], "envelope.fill", Theme.blue),
            (["ai", "claude", "codex", "cursor"], "brain", Theme.purple),
        ]
        for (keywords, symbol, tint) in table where keywords.contains(where: { n.contains($0) }) {
            return CleanSectionStyle(symbol: symbol, tint: tint)
        }
        return CleanSectionStyle(symbol: "folder.fill", tint: Theme.teal)
    }
}
