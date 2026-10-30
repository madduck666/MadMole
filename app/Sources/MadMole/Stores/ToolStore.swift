import Foundation
import Observation

/// Describes one engine command shown as a "preview, then run" page.
struct ToolSpec {
    let page: Page
    let command: String
    let heroTitle: String
    let heroMessage: String
    let bullets: [String]
    let runTitle: String
    let confirmMessage: String
    /// The engine's dry-run flag for this command.
    var dryRunFlag = "--dry-run"
    var extraActions: [(title: String, arguments: [String])] = []

    static func spec(for page: Page) -> ToolSpec? {
        switch page {
        case .optimize:
            return ToolSpec(
                page: .optimize,
                command: "optimize",
                heroTitle: "Sistemi tazeleyin",
                heroMessage: "Önbellekleri yeniden oluşturur, bozuk tercihleri onarır ve bazı sistem servislerini güvenle yeniler. Her adım önceden açıklanır.",
                bullets: [
                    "DNS ve sistem önbelleklerini yeniler",
                    "Spotlight ve LaunchServices bakımını yapar",
                    "Bozuk tercih dosyalarını onarır",
                    "Yönetici izni gereken adımlar terminalde sorulur",
                ],
                runTitle: "Optimize Et",
                confirmMessage: "Optimizasyon terminal penceresinde çalışır ve bazı adımlar için yönetici izni isteyebilir.",
                extraActions: [("Korunan öğeleri düzenle…", ["optimize", "--whitelist"])]
            )
        case .purge:
            return ToolSpec(
                page: .purge,
                command: "purge",
                heroTitle: "Eski proje artıklarını bulun",
                heroMessage: "Projelerinizdeki node_modules, target, build, .venv gibi yeniden oluşturulabilir klasörleri bulur. Son 7 günde dokunulan projeler korunur.",
                bullets: [
                    "Kilit dosyası ve kurulum kaydı olan bağımlılık klasörleri",
                    "Aktif ve yakın zamanda kullanılan projeler atlanır",
                    "Terminalde hangilerinin silineceğini siz seçersiniz",
                ],
                runTitle: "Artıkları Seç ve Sil",
                confirmMessage: "Terminalde bulunan klasörlerin listesi açılır; silinecekleri ok tuşları ve boşluk ile seçip Enter'a basarsınız."
            )
        case .installer:
            return ToolSpec(
                page: .installer,
                command: "installer",
                heroTitle: "Kurulum dosyalarını temizleyin",
                heroMessage: "İndirilenler ve diğer yaygın konumlardaki .dmg, .pkg, .iso, .xip ve .zip kurulum dosyalarını bulur.",
                bullets: [
                    "Uygulamayı kurduktan sonra unutulan disk görüntüleri",
                    "Eski macOS ve Xcode kurulum arşivleri",
                    "Silinecek dosyaları terminalde siz seçersiniz",
                ],
                runTitle: "Dosyaları Seç ve Sil",
                confirmMessage: "Terminalde bulunan kurulum dosyaları listelenir; silinecekleri seçip onaylarsınız."
            )
        case .slim:
            return ToolSpec(
                page: .slim,
                command: "slim",
                heroTitle: "Uygulamaları inceltin",
                heroMessage: "Apple Silicon'da gereksiz olan Intel kodunu evrensel uygulamalardan çıkarır. Her uygulama önce bir kopya üzerinde inceltilir ve imza/Gatekeeper kontrolünden geçerse asıl uygulamanın yerini alır.",
                bullets: [
                    "Orijinal uygulama Çöp Sepeti'ne taşınır, geri alınabilir",
                    "İmza doğrulamasını geçemeyen uygulamalara dokunulmaz",
                    "Uygulama güncellendiğinde Intel kodu geri gelir",
                ],
                runTitle: "İnceltmeyi Başlat",
                confirmMessage: "İnceltme terminal penceresinde çalışır ve uygulamaları tek tek işler."
            )
        default:
            return nil
        }
    }
}

/// Runs a command's dry run without a terminal and keeps its output.
@MainActor
@Observable
final class ToolStore {
    let spec: ToolSpec
    private(set) var output: [String] = []
    private(set) var isRunning = false
    private(set) var finished = false
    private(set) var exitStatus: Int32?
    private(set) var startedAt: Date?
    private(set) var lastRunAt: Date?
    var console: ConsoleLog?
    private var task: Task<Void, Never>?

    init(spec: ToolSpec) {
        self.spec = spec
    }

    func preview() {
        guard !isRunning else { return }
        isRunning = true
        finished = false
        output = []
        exitStatus = nil
        startedAt = Date()
        let args = [spec.command, spec.dryRunFlag]
        console?.append("mo " + args.joined(separator: " "), source: spec.command)
        let consoleSink = console?.sink(source: spec.command)
        task = Task {
            do {
                let result = try await CommandRunner.mole(args) { line in
                    consoleSink?(line)
                    Task { @MainActor in self.append(line) }
                }
                self.exitStatus = result.status
            } catch {
                self.append(error.localizedDescription)
                self.exitStatus = -1
            }
            self.isRunning = false
            self.finished = true
            self.lastRunAt = Date()
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func append(_ line: String) {
        let text = TextUtils.stripANSI(line)
        if TextUtils.isDecoration(text) { return }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            // Keep at most one blank line in a row.
            if let last = output.last, last.isEmpty { return }
            if output.isEmpty { return }
            output.append("")
            return
        }
        output.append(text)
    }
}
