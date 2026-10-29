import Foundation
import Observation

/// A disk explorer over `analyze-go --json`. Trash moves go through
/// `analyze-go --trash`, which applies analyze's protected-path rules and
/// writes the same operations.log rows as the terminal analyzer.
@MainActor
@Observable
final class AnalyzeStore {
    /// `nil` path means the machine-wide overview.
    struct Location: Hashable {
        var path: String?
        var title: String {
            guard let path else { return "Tüm Disk" }
            if path == Engine.homeDirectory { return "Ana Klasör" }
            return (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        }
    }

    private(set) var location: Location?
    private(set) var result: AnalyzeResult?
    private(set) var isScanning = false
    private(set) var startedAt: Date?
    private(set) var errorMessage: String?
    private(set) var backStack: [Location] = []
    private(set) var isTrashing = false
    var lastTrashReport: TrashReport?
    var selection: Set<String> = []
    var filterText = ""
    var console: ConsoleLog?
    private var task: Task<Void, Never>?
    private var cache: [Location: AnalyzeResult] = [:]

    var entries: [AnalyzeEntry] {
        let list = (result?.entries ?? []).sorted { $0.size > $1.size }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var largestSize: Int64 {
        max(result?.entries?.map(\.size).max() ?? 1, 1)
    }

    var selectedEntries: [AnalyzeEntry] {
        let all = (result?.entries ?? []) + (result?.largeFiles ?? []).map {
            AnalyzeEntry(name: $0.name, path: $0.path, size: $0.size, isDir: false)
        }
        var seen = Set<String>()
        return all.filter { selection.contains($0.path) && seen.insert($0.path).inserted }
    }

    var canGoBack: Bool { !backStack.isEmpty }

    func open(_ newLocation: Location, pushHistory: Bool = true, forceRefresh: Bool = false) {
        if pushHistory, let current = location, current != newLocation {
            backStack.append(current)
        }
        location = newLocation
        selection = []
        filterText = ""
        if !forceRefresh, let cached = cache[newLocation] {
            result = cached
            errorMessage = nil
            return
        }
        scan(newLocation)
    }

    func openDirectory(_ path: String) {
        open(Location(path: path))
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        open(previous, pushHistory: false)
    }

    func refresh() {
        guard let location else { return }
        cache[location] = nil
        open(location, pushHistory: false, forceRefresh: true)
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    private func scan(_ target: Location) {
        task?.cancel()
        isScanning = true
        errorMessage = nil
        result = nil
        startedAt = Date()
        var args = ["--json"]
        if let path = target.path { args.append(path) }
        console?.append("mo analyze " + args.joined(separator: " "), source: "analyze")
        task = Task {
            do {
                let output = try await CommandRunner.run(Engine.analyzeBinary, args)
                if Task.isCancelled { return }
                guard output.succeeded else {
                    throw CommandError.failed(status: output.status, message: output.stderr)
                }
                let decoded = try JSONDecoder.engine.decode(AnalyzeResult.self, from: output.stdout)
                self.cache[target] = decoded
                if self.location == target {
                    self.result = decoded
                }
            } catch is DecodingError {
                if self.location == target {
                    self.errorMessage = CommandError.decoding("disk analizi").localizedDescription
                }
            } catch {
                if !Task.isCancelled, self.location == target {
                    self.errorMessage = error.localizedDescription
                }
            }
            if self.location == target {
                self.isScanning = false
            }
        }
    }

    /// Moves the given paths to the Trash through the engine, then rescans.
    func moveToTrash(_ paths: [String]) {
        guard !paths.isEmpty, !isTrashing else { return }
        isTrashing = true
        console?.append("mo analyze --trash (\(paths.count) öğe)", source: "analyze")
        Task {
            do {
                let output = try await CommandRunner.run(Engine.analyzeBinary, ["--trash"] + paths)
                if let report = try? JSONDecoder.engine.decode(TrashReport.self, from: output.stdout) {
                    self.lastTrashReport = report
                    for row in report.results {
                        self.console?.append((row.ok ? "Çöpe taşındı: " : "Atlandı: ") + row.path + (row.error.map { " (\($0))" } ?? ""), source: "analyze")
                    }
                } else {
                    throw CommandError.failed(status: output.status, message: output.stderr)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isTrashing = false
            self.selection = []
            // Every cached listing above a moved path is stale now.
            self.cache.removeAll()
            self.refresh()
        }
    }
}
