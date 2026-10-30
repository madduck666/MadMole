import AppKit
import SwiftUI

/// The "check for updates" sheet: checking, up to date, a new build with
/// its notes, progress, or an error.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var store: UpdateStore { model.updates }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MadMole Güncellemeleri")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Kurulu sürüm: \(store.currentVersion) (build \(store.currentBuild))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            content

            HStack {
                if let page = store.latest?.pageURL ?? UpdateClient.releasesPage {
                    Link("Sürüm sayfası", destination: page)
                        .font(.callout)
                }
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(store.phase == .installing)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Yeni sürüm denetleniyor…")
            }
        case .upToDate:
            Label("En güncel sürümü kullanıyorsunuz.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.green)
                .font(.headline)
        case .available:
            if let release = store.latest {
                releaseDetails(release)
            }
        case .downloading:
            progress("Yeni sürüm indiriliyor…")
        case .installing:
            progress("Doğrulanıyor ve kuruluyor; MadMole birazdan yeniden açılacak…")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                ErrorBanner(message: message)
                HStack {
                    Button("Uygulama Yönetimi izni") { PrivacyPane.open(.appManagement) }
                    Button("Tanılama Bilgisini Kopyala") { Diagnostics.copyReport(model: model) }
                }
                .controlSize(.small)
            }
        }
    }

    private func releaseDetails(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("MadMole \(release.version) hazır", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.blue)
            if let date = release.publishedAt {
                Text("Yayın: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
            if model.terminalJob != nil {
                Label("Önce açık olan terminal işlemini bitirin.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.orange)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
                .progressViewStyle(.linear)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch store.phase {
        case .available:
            Button("Daha Sonra") { dismiss() }
            Button("Güncelle ve Yeniden Başlat") { store.install() }
                .buttonStyle(GradientButtonStyle(tint: Theme.blue))
                .keyboardShortcut(.defaultAction)
                .disabled(model.terminalJob != nil)
        case .failed:
            Button("Kapat") { dismiss() }
            Button("Tekrar Dene") { store.check(userInitiated: true) }
                .keyboardShortcut(.defaultAction)
        case .downloading, .installing:
            EmptyView()
        default:
            Button("Kapat") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A small banner at the bottom of the sidebar when a new build is waiting.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.updates.updateAvailable, let release = model.updates.latest {
            Button {
                model.updates.showSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Güncelleme hazır")
                            .font(.caption.weight(.bold))
                        Text("MadMole \(release.version)")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    Text("Kur")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.25)))
                        .foregroundStyle(.white)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.blue, Theme.indigo], startPoint: .leading, endPoint: .trailing))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }
}

/// The updates card in Settings.
struct UpdateSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var autoCheck = UserDefaults.standard.object(forKey: UpdateStore.autoCheckKey) as? Bool ?? true

    var body: some View {
        let store = model.updates
        Card(title: "Güncellemeler", symbol: "arrow.triangle.2.circlepath", tint: Theme.blue) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sürüm \(store.currentVersion) (build \(store.currentBuild))")
                        .fontWeight(.medium)
                    Text(statusText(store))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.updateAvailable {
                    Button("Güncellemeyi Kur") { store.showSheet = true }
                        .buttonStyle(GradientButtonStyle(tint: Theme.blue))
                } else {
                    Button("Güncellemeleri Denetle") { store.check(userInitiated: true) }
                        .disabled(store.isBusy)
                }
            }
            Label(SigningInfo.usesCertificate
                  ? "Sabit sertifikayla imzalı: izinler güncellemelerde korunur."
                  : "Geçici (ad hoc) imzalı: macOS her güncellemede Tam Disk Erişimi'ni düşürebilir.",
                  systemImage: SigningInfo.usesCertificate ? "checkmark.shield" : "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(SigningInfo.usesCertificate ? Theme.green : Theme.orange)
            Toggle("Açılışta yeni sürümü otomatik denetle", isOn: $autoCheck)
                .toggleStyle(.checkbox)
                .onChange(of: autoCheck) { _, value in store.autoCheck = value }
        }
    }

    private func statusText(_ store: UpdateStore) -> String {
        switch store.phase {
        case .checking: return "Denetleniyor…"
        case .upToDate:
            return "Güncel" + (store.lastChecked.map { " · son denetim " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
        case .available: return "Yeni sürüm: \(store.latest?.version ?? "")"
        case .downloading: return "İndiriliyor…"
        case .installing: return "Kuruluyor…"
        case .failed: return "Son denetim başarısız oldu"
        case .idle: return "Yeni sürümler GitHub'daki \(UpdateClient.repository) deposundan gelir"
        }
    }
}
