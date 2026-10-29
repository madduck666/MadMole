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

    private func run(dryRun: Bool) {
        let names = store.selectedApps.map(\.name).joined(separator: ", ")
        model.runInTerminal(
            title: dryRun ? "Kaldırma Önizlemesi" : "Uygulama Kaldırma",
            subtitle: names,
            arguments: store.uninstallArguments(dryRun: dryRun, withData: withData),
            tint: Page.uninstall.tint
        ) { _ in
            if !dryRun {
                store.selection.removeAll()
                store.load()
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
