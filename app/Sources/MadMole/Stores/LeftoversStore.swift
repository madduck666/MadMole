import Foundation
import Observation

/// Leftovers of removed apps and unfinished updates. A read-only scan makes
/// suggestions; only what the user ticks moves to the Trash, through the
/// engine's `mole_delete` funnel.
@MainActor
@Observable
final class LeftoversStore {
    private(set) var items: [Leftover] = []
    private(set) var isScanning = false
    private(set) var isTrashing = false
    private(set) var scannedAt: Date?
    private(set) var errorMessage: String?
    private(set) var lastResults: [EngineHelper.PathResult] = []
    var selection: Set<String> = []
    var console: ConsoleLog?
    var helper = EngineHelper()
    var scanner = LeftoverScanner()

    var selectedItems: [Leftover] { items.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    func groups() -> [(Leftover.Kind, [Leftover])] {
        Leftover.Kind.allCases.compactMap { kind in
            let list = items.filter { $0.kind == kind }.sorted { $0.sizeBytes > $1.sizeBytes }
            return list.isEmpty ? nil : (kind, list)
        }
    }

    func scan() {
        guard !isScanning, !isTrashing else { return }
        isScanning = true
        errorMessage = nil
        selection = []
        console?.append("Sahipsiz artık taraması", source: "leftovers")
        let scanner = scanner
        let helper = helper
        Task {
            do {
                let candidates = await Task.detached { scanner.dataCandidates() }.value
                let report = try await helper.orphans(candidates.map { (id: $0.id, path: $0.path) })
                let found = await Task.detached { () -> [Leftover] in
                    let data = scanner.appData(candidates: candidates, report: report)
                    let launch = scanner.launchItems(orphanFolders: data.map(\.path))
                    var all = data + launch + scanner.partialUpdates()
                    for index in all.indices {
                        all[index].sizeBytes = DiskUsage.allocatedSize(of: all[index].path)
                    }
                    return all
                }.value
                self.items = found
                self.scannedAt = Date()
                self.console?.append("\(found.count) öneri bulundu", source: "leftovers")
            } catch {
                self.items = []
                self.errorMessage = Self.explain(error)
            }
            self.isScanning = false
        }
    }

    static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("installed apps could not be scanned") {
            let detail = text.components(separatedBy: "scanned: ").dropFirst().first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var message = "Motor yüklü uygulamaların listesini eksiksiz çıkaramadı; liste eksikken hiçbir klasöre \"sahipsiz\" denmez, bu yüzden tarama durdu."
            if let detail, !detail.isEmpty {
                message += " Sorunlu öğe: \(detail). İçinde uygulama bilgisi olmayan bozuk bir uygulama olabilir; onu kaldırıp ya da yeniden kurup tekrar deneyin."
            }
            return message
        }
        return text
    }

    func toggle(_ item: Leftover) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func trashSelected() {
        let paths = selectedItems.map(\.path)
        guard !paths.isEmpty, !isTrashing else { return }
        isTrashing = true
        console?.append("Çöp'e taşınıyor: \(paths.count) öğe", source: "leftovers")
        Task {
            do {
                let results = try await helper.trash(paths, command: "madmole-leftovers")
                self.lastResults = results
                let moved = Set(results.filter { $0.verdict == .allowed }.map(\.path))
                self.items.removeAll { moved.contains($0.path) }
                self.selection.subtract(moved)
                for result in results where result.verdict != .allowed {
                    self.console?.append("Taşınamadı: \(result.path)", source: "leftovers")
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isTrashing = false
        }
    }
}
