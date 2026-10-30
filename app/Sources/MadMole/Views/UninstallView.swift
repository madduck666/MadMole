import AppKit
import SwiftUI

struct UninstallView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: UninstallStore
    @State private var withData = false
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .uninstall) {
                if !store.apps.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(store.apps.count) uygulama")
                            .font(.callout.weight(.semibold))
                        Text("Toplam \(TextUtils.formatBytes(store.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)

            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            if store.isLoading && store.apps.isEmpty {
                WorkingPanel(title: "Yüklü uygulamalar taranıyor…", detail: "Boyutlar ve Homebrew sahipliği hesaplanıyor",
                             tint: Page.uninstall.tint)
            } else if let error = store.errorMessage, store.apps.isEmpty {
                VStack {
                    ErrorBanner(message: error) { store.load() }
                    Spacer()
                }
                .padding(.horizontal, 24)
            } else {
                appList
            }

            if !store.selection.isEmpty {
                actionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.selection.isEmpty)
        .onAppear { store.loadIfNeeded() }
        .sheet(isPresented: Binding(
            get: { !store.blockedApps.isEmpty },
            set: { if !$0 { store.blockedApps = [] } }
        )) {
            UninstallBlockedSheet(store: store) { apps in
                store.blockedApps = []
                // Let this sheet close before the terminal sheet opens.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    run(dryRun: false, debug: true, apps: apps)
                }
            }
        }
        .confirmationDialog("Seçili uygulamalar kaldırılsın mı?", isPresented: $confirmUninstall) {
            Button("Kaldırmaya Devam Et", role: .destructive) { run(dryRun: false) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Terminal penceresinde Mole kaldırılacak her dosyayı listeler ve son onayınızı ister. Dosyalar varsayılan olarak Çöp Sepeti'ne taşınır.")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Uygulama ara", text: $store.searchText)
                    .textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 320)

            Picker("Sırala", selection: $store.sortOrder) {
                ForEach(UninstallStore.SortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            Toggle("Sadece Homebrew", isOn: $store.onlyHomebrew)
                .toggleStyle(.checkbox)

            Spacer()

            if store.isLoading && !store.apps.isEmpty {
                ProgressView().controlSize(.small)
            }
            Button {
                store.load()
            } label: {
                Label("Yenile", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)
        }
    }

    private var appList: some View {
        let apps = store.visibleApps
        let maxSize = max(apps.map(\.sizeBytes).max() ?? 1, 1)
        return ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(apps) { app in
                    AppRow(app: app,
                           isSelected: store.selection.contains(app.id),
                           fraction: Double(app.sizeBytes) / Double(maxSize)) {
                        store.toggle(app)
                    }
                }
                if apps.isEmpty && !store.apps.isEmpty {
                    Text("Aramanızla eşleşen uygulama yok.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: -10) {
                ForEach(store.selectedApps.prefix(4)) { app in
                    FileIcon(path: app.path, size: 30)
                        .shadow(radius: 1)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(store.selection.count) uygulama seçildi")
                    .font(.callout.weight(.semibold))
                Text("Uygulama boyutu: \(TextUtils.formatBytes(store.selectedBytes)) (artıklar terminalde hesaplanır)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Kişisel verileri de seç", isOn: $withData)
                .toggleStyle(.checkbox)
                .help("--with-data: uygulamanın kişisel verilerini başlangıçta seçili getirir; terminalde yine tek tek kaldırabilirsiniz")
            Button("Seçimi Temizle") { store.selection.removeAll() }
                .buttonStyle(.borderless)
            Button {
                run(dryRun: true)
            } label: {
                Label("Önizle", systemImage: "eye")
            }
            Button {
                confirmUninstall = true
            } label: {
                Label("Kaldır", systemImage: "trash")
            }
            .buttonStyle(GradientButtonStyle(tint: Page.uninstall.tint))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func run(dryRun: Bool, debug: Bool = false, apps: [InstalledApp]? = nil) {
        let targets = apps ?? store.selectedApps
        let names = targets.map(\.name).joined(separator: ", ")
        var arguments = ["uninstall"]
        if dryRun { arguments.append("--dry-run") }
        if withData { arguments.append("--with-data") }
        if debug { arguments.append("--debug") }
        arguments += targets.map(\.uninstallName)
        let logOffset = DeletionsLog.currentOffset()
        model.runInTerminal(
            title: dryRun ? "Kaldırma Önizlemesi" : "Uygulama Kaldırma",
            subtitle: names,
            arguments: arguments,
            tint: Page.uninstall.tint
        ) { _ in
            guard !dryRun else { return }
            store.selection.removeAll()
            store.load()
            // Wait for the terminal sheet to close before another sheet opens.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                store.noteFinishedRun(attempted: targets, logOffset: logOffset)
            }
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let isSelected: Bool
    let fraction: Double
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isSelected ? Page.uninstall.tint : Color.secondary.opacity(0.6))
            FileIcon(path: app.path, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if app.isHomebrew {
                        Badge(text: "Homebrew", tint: Theme.orange)
                    }
                }
                Text(app.bundleId.isEmpty ? TextUtils.abbreviatePath(app.path) : app.bundleId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            CapsuleBar(fraction: fraction, tint: Page.uninstall.tint.opacity(0.8), height: 5)
                .frame(width: 110)
            Text(app.sizeBytes > 0 ? TextUtils.formatBytes(app.sizeBytes) : app.size)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Page.uninstall.tint.opacity(0.10) : (hovering ? Color.primary.opacity(0.045) : Theme.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? Page.uninstall.tint.opacity(0.45) : Theme.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Finder'da Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Button("Paket kimliğini kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.bundleId, forType: .string)
            }
            .disabled(app.bundleId.isEmpty)
        }
    }
}

/// Shown when macOS refused to move a selected app to the Trash: the two
/// privacy settings involved, a retry with a detailed log, and a last-resort
/// Trash move through macOS itself.
private struct UninstallBlockedSheet: View {
    let store: UninstallStore
    let retry: ([InstalledApp]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "hand.raised.fill", tint: Theme.orange, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS kaldırmaya izin vermedi")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(store.blockedApps.map(\.name).joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("macOS, başka bir uygulamanın Uygulamalar klasöründeki programları değiştirmesini özel izinle sınırlar. MadMole'a bu izni bir kez verdiğinizde kaldırma çalışır.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Uygulama Yönetimi listesinde MadMole'u açın.", button: "Uygulama Yönetimi") {
                    PrivacyPane.open(.appManagement)
                }
                step(2, "Otomasyon listesinde MadMole altındaki Finder anahtarını açın. Liste boşsa \"Tekrar Dene\" sonrası macOS size soracak; İzin Ver deyin.", button: "Otomasyon") {
                    PrivacyPane.open(.automation)
                }
                step(3, "Kaldırmak istediğiniz uygulama açıksa kapatın, sonra Tekrar Dene'ye basın.", button: nil) {}
            }

            if let message = store.fallbackMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                let direct = store.blockedApps.filter {
                    UninstallStore.canTrashDirectly($0) && FileManager.default.fileExists(atPath: $0.path)
                }
                if !direct.isEmpty {
                    Button("macOS ile Çöp'e Taşı") {
                        for app in direct { store.trashDirectly(app) }
                    }
                    .help("Uygulamayı macOS'un kendi Çöp Sepeti hizmetiyle taşır; gerekirse Mac şifrenizi sorar. Artıkları daha sonra Akıllı Temizlik bulur.")
                }
                Spacer()
                Button("Kapat") { dismiss() }
                Button("Tekrar Dene") {
                    let apps = store.blockedApps
                    retry(apps)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(GradientButtonStyle(tint: Page.uninstall.tint))
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(_ number: Int, _ text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.orange))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let button {
                Button(button, action: action)
            }
        }
    }
}
