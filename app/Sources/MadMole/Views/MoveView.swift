import AppKit
import SwiftUI

struct MoveView: View {
    @Bindable var store: MoveStore
    @State private var confirmStart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(page: .move)
                sourceCard
                volumeCard
                if let volume = store.volume, volume.isEncrypted != true {
                    unencryptedWarning(volume)
                }
                if let refusal = store.refusal {
                    ErrorBanner(message: refusal)
                }
                ForEach(store.problems, id: \.message) { problem in
                    ErrorBanner(message: problem.message)
                }
                actionCard
                if store.phase != .idle || store.report != nil {
                    progressCard
                }
            }
            .padding(24)
        }
        .onAppear { store.refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            store.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            store.refreshVolumes()
        }
        .confirmationDialog("Taşıma başlasın mı?", isPresented: $confirmStart) {
            Button("Kopyala, Doğrula ve Taşı") { store.start() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Önce kopyalanır, sonra her dosya baytı baytına karşılaştırılır. Yalnızca hepsi aynıysa asıl öğe Çöp Sepeti'ne taşınır; kalıcı olarak silinmez.")
        }
    }

    // MARK: Cards

    private var sourceCard: some View {
        Card(title: "1. Taşınacak öğe", symbol: "doc.on.doc", tint: Page.move.tint) {
            HStack(spacing: 12) {
                if let source = store.source {
                    FileIcon(path: source.path, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.lastPathComponent)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(TextUtils.abbreviatePath(source.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if store.isMeasuring {
                        ProgressView().controlSize(.small)
                    } else if let bytes = store.sourceBytes {
                        Text(TextUtils.formatBytes(bytes))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                } else {
                    Text("Bir klasör ya da dosya seçin. Disk Analizi ekranından da \"Harici Diske Taşı\" ile gelebilirsiniz.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button("Seç…", action: chooseSource)
                    .disabled(store.isBusy)
            }
        }
    }

    private var volumeCard: some View {
        Card(title: "2. Hedef disk", symbol: "externaldrive", tint: Page.move.tint) {
            if store.volumes.isEmpty {
                HStack {
                    Text("Bağlı harici disk yok. Diski takın; liste kendiliğinden yenilenir.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Yenile") { store.refreshVolumes() }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.volumes) { volume in
                        volumeRow(volume)
                    }
                    HStack(spacing: 8) {
                        Text("Hedef klasör:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(store.destinationFolder.map { TextUtils.abbreviatePath($0.path) } ?? "—")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Klasör Seç…", action: chooseFolder)
                            .disabled(store.volume == nil || store.isBusy)
                        Button("Yenile") { store.refreshVolumes() }
                            .disabled(store.isBusy)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func volumeRow(_ volume: ExternalVolume) -> some View {
        let selected = store.volume?.id == volume.id
        return Button {
            store.choose(volume: volume)
        } label: {
            volumeLabel(volume, selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }

    private func volumeLabel(_ volume: ExternalVolume, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Page.move.tint : .secondary)
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.secondary)
            Text(volume.name)
                .font(.callout.weight(.medium))
            if volume.isEncrypted == true {
                Badge(text: "Şifreli", tint: Theme.green)
            } else {
                Badge(text: volume.isEncrypted == nil ? "Şifre durumu bilinmiyor" : "Şifresiz", tint: Theme.orange)
            }
            Spacer()
            Text("\(TextUtils.formatBytes(volume.availableBytes)) boş / \(TextUtils.formatBytes(volume.totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Page.move.tint.opacity(0.10) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
    }

    private func unencryptedWarning(_ volume: ExternalVolume) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.open.fill")
                .foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.isEncrypted == nil ? "\(volume.name) diskinin şifreli olup olmadığı anlaşılamadı" : "\(volume.name) şifreli değil")
                    .font(.callout.weight(.semibold))
                Text("Disk kaybolur ya da çalınırsa içindekileri herkes okuyabilir. Hasta verisi, kimlik ve kişisel belgeler gibi hassas dosyaları bu diske taşımayın.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.12)))
    }

    private var actionCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Taşıyınca bu dosyaların tek kopyası harici diskte kalır.")
                    .font(.callout.weight(.semibold))
                Text("İkinci bir yedek önerilir: aynı dosyaları başka bir diske ya da yedekleme hizmetine de koyun.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isBusy {
                Button("Durdur", role: .cancel) { store.cancel() }
                    .disabled(store.phase == .trashing)
            }
            Button {
                confirmStart = true
            } label: {
                Label("Taşı", systemImage: "arrow.right.doc.on.clipboard")
            }
            .buttonStyle(GradientButtonStyle(tint: Page.move.tint))
            .disabled(store.source == nil || store.destinationFolder == nil || store.isBusy || store.isMeasuring)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var progressCard: some View {
        Card(title: "Durum", symbol: "list.bullet.clipboard", tint: Page.move.tint) {
            VStack(alignment: .leading, spacing: 10) {
                step("Korunan yollar ve boş yer denetimi", state: state(for: .checking))
                step(copyLabel, state: state(for: .copying))
                step(verifyLabel, state: state(for: .verifying))
                step("Aslı Çöp Sepeti'ne", state: state(for: .trashing))

                if let report = store.report {
                    Divider()
                    HStack(spacing: 18) {
                        count("Dosya", report.files, tint: .primary)
                        count("Klasör", report.folders, tint: .primary)
                        count("Eksik", report.missing, tint: report.missing == 0 ? Theme.green : Theme.red)
                        count("Farklı", report.different, tint: report.different == 0 ? Theme.green : Theme.red)
                        count("Okunamadı", report.unreadable, tint: report.unreadable == 0 ? Theme.green : Theme.red)
                    }
                    if !report.examples.isEmpty {
                        Text("Uymayanlar: " + report.examples.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                }

                if case let .failed(message) = store.phase {
                    ErrorBanner(message: message)
                }
                if store.phase == .done, let target = store.copyTarget {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Theme.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Taşındı. Kopya birebir aynı, aslı Çöp Sepeti'nde.")
                                .font(.callout.weight(.semibold))
                            Text("Bu dosyaların artık tek kopyası harici diskte. İkinci bir yedek önerilir. Çöp Sepeti'ni boşaltmak size kalmış; boşaltana kadar geri alabilirsiniz.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Kopyayı Finder'da Göster") {
                                NSWorkspace.shared.activateFileViewerSelecting([target])
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.green.opacity(0.12)))
                }
            }
        }
    }

    private var copyLabel: String {
        guard store.phase == .copying, let total = store.sourceBytes, total > 0 else { return "Kopyalama (ditto)" }
        return "Kopyalama (ditto): \(TextUtils.formatBytes(store.copiedBytes)) / \(TextUtils.formatBytes(total)) (yaklaşık)"
    }

    private var verifyLabel: String {
        guard store.phase == .verifying, let total = store.sourceBytes, total > 0 else { return "Baytı baytına karşılaştırma" }
        return "Baytı baytına karşılaştırma: \(TextUtils.formatBytes(store.comparedBytes)) / \(TextUtils.formatBytes(total))"
    }

    private enum StepState { case waiting, running, done, stopped }

    private func state(for phase: MoveStore.Phase) -> StepState {
        let order: [MoveStore.Phase] = [.checking, .copying, .verifying, .trashing]
        guard let mine = order.firstIndex(of: phase) else { return .waiting }
        if store.phase == .done { return .done }
        let current = store.currentStep
        if mine < current { return .done }
        guard mine == current else { return .waiting }
        if store.isBusy { return .running }
        if case .failed = store.phase { return .stopped }
        return store.problems.isEmpty ? .waiting : .stopped
    }

    private func step(_ title: String, state: StepState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
            case .stopped: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
            }
            Text(title)
                .font(.callout)
                .monospacedDigit()
        }
    }

    private func count(_ title: String, _ value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pickers

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: Engine.homeDirectory)
        panel.prompt = "Seç"
        if panel.runModal() == .OK, let url = panel.url {
            store.choose(source: url)
        }
    }

    private func chooseFolder() {
        guard let volume = store.volume else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = volume.url
        panel.prompt = "Hedef Yap"
        if panel.runModal() == .OK, let url = panel.url {
            store.choose(folder: url)
        }
    }
}
