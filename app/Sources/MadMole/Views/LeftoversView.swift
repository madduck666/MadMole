import AppKit
import SwiftUI

struct LeftoversView: View {
    @Bindable var store: LeftoversStore
    @State private var confirmTrash = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .leftovers) {
                if store.scannedAt != nil, !store.items.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(store.items.count) öneri")
                            .font(.callout.weight(.semibold))
                        Text("Toplam \(TextUtils.formatBytes(store.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    store.scan()
                } label: {
                    Label(store.scannedAt == nil ? "Tara" : "Yeniden Tara", systemImage: "magnifyingglass")
                }
                .disabled(store.isScanning || store.isTrashing)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)

            if let error = store.errorMessage {
                ErrorBanner(message: error) { store.scan() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            if store.isScanning {
                WorkingPanel(title: "Artıklar aranıyor…", detail: "Yüklü uygulamalar motorla karşılaştırılıyor",
                             tint: Page.leftovers.tint)
            } else if store.scannedAt == nil {
                HeroPrompt(page: .leftovers,
                           title: "Kaldırılmış uygulamalardan kalanlar",
                           message: "Uygulaması artık yüklü olmayan veri klasörlerini, yarım kalmış güncellemeleri ve programı kalmamış açılış kayıtlarını bulur. Liste yalnızca öneridir; siz seçmedikçe hiçbir şeye dokunulmaz.",
                           bullets: [
                               "Kararı motorun kendi kuralları verir: Apple klasörleri, korunan yollar ve parola yöneticisi gibi hassas veriler hiç listelenmez",
                               "Son 30 günde değişmiş klasörler önerilmez",
                               "Seçtikleriniz Çöp Sepeti'ne taşınır, kalıcı olarak silinmez",
                           ]) {
                    Button {
                        store.scan()
                    } label: {
                        Label("Tara", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(GradientButtonStyle(tint: Page.leftovers.tint))
                }
            } else if store.items.isEmpty, store.errorMessage == nil {
                ContentUnavailableView("Artık bulunamadı", systemImage: "checkmark.seal",
                                       description: Text("Kaldırılmış bir uygulamadan kalan veri ya da yarım güncelleme görünmüyor."))
            } else {
                list
            }

            if !store.selection.isEmpty {
                actionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.selection.isEmpty)
        .confirmationDialog("Seçili öğeler Çöp Sepeti'ne taşınsın mı?", isPresented: $confirmTrash) {
            Button("Çöp'e Taşı", role: .destructive) { store.trashSelected() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("\(store.selection.count) öğe, \(TextUtils.formatBytes(store.selectedBytes)). Motor her öğeyi korunan yollarla bir kez daha denetler; kalıcı silme yapılmaz, Çöp Sepeti'nden geri alabilirsiniz.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                let refused = store.lastResults.filter { $0.verdict != .allowed }
                if !refused.isEmpty {
                    ErrorBanner(message: refused.map { result -> String in
                        switch result.verdict {
                        case let .refused(reason): return "\(TextUtils.abbreviatePath(result.path)): \(EngineHelper.describe(reason: reason))"
                        case let .failed(status): return "\(TextUtils.abbreviatePath(result.path)): taşınamadı (kod \(status)); Finder'dan kendiniz taşıyabilirsiniz"
                        case .allowed: return ""
                        }
                    }.joined(separator: "\n"))
                }
                ForEach(store.groups(), id: \.0) { kind, items in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(kind.rawValue)
                                .font(.headline)
                            Text("\(items.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(kind.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(items) { item in
                            LeftoverRow(item: item, isSelected: store.selection.contains(item.id)) {
                                store.toggle(item)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(store.selection.count) öğe seçildi")
                    .font(.callout.weight(.semibold))
                Text(TextUtils.formatBytes(store.selectedBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Seçimi Temizle") { store.selection.removeAll() }
                .buttonStyle(.borderless)
            Button {
                confirmTrash = true
            } label: {
                if store.isTrashing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Çöp'e Taşı", systemImage: "trash")
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
}

private struct LeftoverRow: View {
    let item: Leftover
    let isSelected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(isSelected ? Page.leftovers.tint : Color.secondary.opacity(0.6))
            FileIcon(path: item.path, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Badge(text: item.location, tint: Theme.gray)
                    if let modified = item.modified {
                        Text("son değişiklik \(modified.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(TextUtils.formatBytes(item.sizeBytes))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Page.leftovers.tint.opacity(0.10) : (hovering ? Color.primary.opacity(0.045) : Theme.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Page.leftovers.tint.opacity(0.45) : Theme.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Finder'da Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Button("Yolu Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
        .help(item.path)
    }
}
