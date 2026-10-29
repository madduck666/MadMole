import Foundation
import Observation

/// The installed-app inventory from `mole uninstall --list` (JSON when piped).
@MainActor
@Observable
final class UninstallStore {
    enum SortOrder: String, CaseIterable, Identifiable {
        case size = "Boyut"
        case name = "İsim"
        var id: String { rawValue }
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var loadedAt: Date?
    var selection: Set<String> = []
    var searchText = ""
    var sortOrder: SortOrder = .size
    var onlyHomebrew = false
    var console: ConsoleLog?
    private var task: Task<Void, Never>?

    var visibleApps: [InstalledApp] {
        var list = apps
        if onlyHomebrew { list = list.filter(\.isHomebrew) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.bundleId.localizedCaseInsensitiveContains(query)
            }
        }
        switch sortOrder {
        case .size: list.sort { $0.sizeBytes > $1.sizeBytes }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var selectedApps: [InstalledApp] {
        apps.filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedApps.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalBytes: Int64 {
        apps.reduce(0) { $0 + $1.sizeBytes }
    }

    func loadIfNeeded() {
        if apps.isEmpty && !isLoading { load() }
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        console?.append("mo uninstall --list", source: "uninstall")
        task = Task {
            do {
                let result = try await CommandRunner.mole(["uninstall", "--list"])
                guard result.succeeded else {
                    throw CommandError.failed(status: result.status, message: result.stderr)
                }
                let decoded = try JSONDecoder.engine.decode([InstalledApp].self, from: result.stdout)
                self.apps = decoded
                self.selection = self.selection.filter { id in decoded.contains { $0.id == id } }
                self.loadedAt = Date()
                self.console?.append("\(decoded.count) uygulama bulundu", source: "uninstall")
            } catch is DecodingError {
                self.errorMessage = CommandError.decoding("uygulama listesi").localizedDescription
            } catch {
                if !Task.isCancelled { self.errorMessage = error.localizedDescription }
            }
            self.isLoading = false
            self.task = nil
        }
    }

    func toggle(_ app: InstalledApp) {
        if selection.contains(app.id) {
            selection.remove(app.id)
        } else {
            selection.insert(app.id)
        }
    }

    /// Arguments for `mo uninstall`; the engine matches each name and shows
    /// the exact plan before anything is removed.
    func uninstallArguments(dryRun: Bool, withData: Bool) -> [String] {
        var args = ["uninstall"]
        if dryRun { args.append("--dry-run") }
        if withData { args.append("--with-data") }
        args.append(contentsOf: selectedApps.map(\.uninstallName))
        return args
    }
}
