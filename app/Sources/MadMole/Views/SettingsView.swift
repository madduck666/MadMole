import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var hasFullDiskAccess = Permissions.hasFullDiskAccess
    @State private var touchIDStatus: String?
    @State private var loadingTouchID = false
    @State private var copiedReport = false
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(page: .settings)

                UpdateSettingsCard()

                Card(title: "Görünüm", symbol: "circle.lefthalf.filled", tint: Theme.indigo) {
                    HStack {
                        Text("Tema")
                        Spacer()
                        Picker("Tema", selection: $appearance) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }

                Card(title: "İzinler", symbol: "lock.shield.fill", tint: Theme.orange) {
                    HStack {
                        Image(systemName: hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(hasFullDiskAccess ? Theme.green : Theme.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tam Disk Erişimi")
                                .fontWeight(.medium)
                            Text(hasFullDiskAccess
                                ? "Verildi. Temizlik ve analiz korumalı klasörleri görebilir."
                                : "Verilmedi. Bazı önbellekler ve Kitaplık klasörleri taranamaz.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ayarları Aç") { Permissions.openFullDiskAccessSettings() }
                        Button("Kontrol Et") { hasFullDiskAccess = Permissions.hasFullDiskAccess }
                            .buttonStyle(.borderless)
                    }
                }

                Card(title: "Korunan Yollar", symbol: "shield.lefthalf.filled", tint: Theme.teal) {
                    Text("Burada seçtiğiniz yollara temizlik ve optimizasyon asla dokunmaz. Sistem dosyaları ve uygulama verileri her durumda yerleşik kurallarla korunur.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            model.runInTerminal(title: "Temizlik — Korunan Yollar", subtitle: "Boşluk ile seçin, Enter ile kaydedin",
                                                arguments: ["clean", "--whitelist"], tint: Page.clean.tint)
                        } label: {
                            Label("Temizlik listesini düzenle", systemImage: Page.clean.symbol)
                        }
                        Button {
                            model.runInTerminal(title: "Optimizasyon — Korunan Öğeler", subtitle: "Boşluk ile seçin, Enter ile kaydedin",
                                                arguments: ["optimize", "--whitelist"], tint: Page.optimize.tint)
                        } label: {
                            Label("Optimizasyon listesini düzenle", systemImage: Page.optimize.symbol)
                        }
                        Spacer()
                        Button("Dosyayı Göster") {
                            NSWorkspace.shared.activateFileViewerSelecting([Engine.whitelistFile])
                        }
                        .buttonStyle(.borderless)
                        .disabled(!FileManager.default.fileExists(atPath: Engine.whitelistFile.path))
                    }
                }

                Card(title: "Touch ID ile yönetici izni", symbol: "touchid", tint: Theme.pink) {
                    Text("Etkinleştirirseniz temizlik ve optimizasyon sırasında istenen yönetici şifresi yerine parmak izinizi kullanabilirsiniz.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if loadingTouchID {
                            ProgressView().controlSize(.small)
                        } else if let touchIDStatus {
                            Text(touchIDStatus)
                                .font(.callout.weight(.medium))
                        }
                        Spacer()
                        Button("Etkinleştir") { touchID("enable") }
                        Button("Devre Dışı Bırak") { touchID("disable") }
                    }
                }

                Card(title: "Sorun Bildir", symbol: "ladybug.fill", tint: Theme.red) {
                    Text("Bir şey beklediğiniz gibi çalışmazsa bu düğmeyle sürüm, izin ve son motor çıktısını panoya kopyalayıp mesajınıza yapıştırın.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            Diagnostics.copyReport(model: model)
                            copiedReport = true
                        } label: {
                            Label(copiedReport ? "Kopyalandı" : "Tanılama Bilgisini Kopyala",
                                  systemImage: copiedReport ? "checkmark" : "doc.on.clipboard")
                        }
                        Spacer()
                    }
                }

                Card(title: "Hakkında", symbol: "info.circle.fill", tint: Theme.indigo) {
                    StatRow(title: "MadMole", value: "\(Engine.appVersion) (build \(UpdateClient.currentBuild))")
                    StatRow(title: "Mole motoru", value: Engine.version)
                    StatRow(title: "Motor konumu", value: TextUtils.abbreviatePath(Engine.rootURL.path))
                    StatRow(title: "Go araçları", value: Engine.hasGoBinaries ? "Hazır" : "Eksik (status/analyze çalışmaz)")
                    Text("MadMole, açık kaynaklı Mole (tw93/Mole, GPL-3.0) temizlik motorunu yerel bir macOS arayüzüyle sunar. Tüm silme işlemleri motorun güvenlik kurallarından, kuru çalıştırma önizlemesinden ve işlem kayıtlarından geçer. Terminal görünümü SwiftTerm (MIT) ile sağlanır.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = Permissions.hasFullDiskAccess
        }
        .onAppear {
            hasFullDiskAccess = Permissions.hasFullDiskAccess
            refreshTouchID()
        }
    }

    private func touchID(_ action: String) {
        model.runInTerminal(title: "Touch ID", subtitle: action == "enable" ? "sudo için Touch ID etkinleştiriliyor" : "sudo için Touch ID kapatılıyor",
                            arguments: ["touchid", action], tint: Theme.pink) { _ in
            refreshTouchID()
        }
    }

    private func refreshTouchID() {
        loadingTouchID = true
        Task {
            let result = try? await CommandRunner.mole(["touchid", "status"])
            let text = TextUtils.stripANSI(result?.output ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            touchIDStatus = text.map { line in
                let lower = line.lowercased()
                if lower.contains("not configured") || lower.contains("disabled") || lower.contains("not enabled") {
                    return "Kapalı"
                }
                if lower.contains("enabled") || lower.contains("configured") {
                    return "Açık"
                }
                return line
            } ?? "Bilinmiyor"
            loadingTouchID = false
        }
    }
}
