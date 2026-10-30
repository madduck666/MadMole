import AppKit
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

    /// What one real uninstall run did, read back from operations.log.
    struct RunSummary: Identifiable {
        let id = UUID()
        let apps: [InstalledApp]
        let removed: [OperationsLog.Entry]
        let kept: [OperationsLog.Entry]
        let fullDiskAccessMissing: Bool

        var removedBytes: Int64 {
            removed.reduce(0) { $0 + (TextUtils.parseSize($1.detail ?? "") ?? 0) }
        }
    }

    var lastSummary: RunSummary?

    /// Apps a real uninstall run left in place, usually because macOS
    /// privacy settings refused the Trash move.
    var blockedApps: [InstalledApp] = []
    private(set) var fallbackMessage: String?

    /// Called when a real uninstall run closes. A selected bundle that is
    /// still on disk and that the engine logged as refused during this run
    /// (privacy-denied, trash-failed and similar) was blocked; one the user
    /// chose to keep at the confirmation has no such row and is left alone.
    func noteFinishedRun(attempted: [InstalledApp], logOffset: UInt64, operationsOffset: UInt64) {
        let entries = OperationsLog.entries(since: operationsOffset)
            .filter { $0.command == "uninstall" }
        let removed = entries.filter { ["TRASHED", "REMOVED"].contains($0.action) }
        let kept = entries.filter { ["SKIPPED", "FAILED"].contains($0.action) }
        if !removed.isEmpty || !kept.isEmpty {
            lastSummary = RunSummary(apps: attempted, removed: removed, kept: kept,
                                     fullDiskAccessMissing: Permissions.fullDiskAccess == .denied)
        }
        let refused = Set(DeletionsLog.rows(since: logOffset)
            .filter { $0.status != "ok" && $0.status != "dry-run" }
            .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        fallbackMessage = nil
        blockedApps = attempted.filter { app in
            FileManager.default.fileExists(atPath: app.path)
                && refused.contains(URL(fileURLWithPath: app.path).standardizedFileURL.path)
        }
    }

    /// The last resort for a bundle the engine could not move: ask macOS
    /// itself (NSWorkspace, the same service Finder uses), which shows its own
    /// password prompt when the bundle needs one. Only exact `.app` bundles
    /// directly inside an Applications folder qualify, never Apple's own.
    static func canTrashDirectly(_ app: InstalledApp) -> Bool {
        let url = URL(fileURLWithPath: app.path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        let allowedParents = ["/Applications", Engine.homeDirectory + "/Applications"]
        return url.pathExtension.lowercased() == "app"
            && allowedParents.contains(parent)
            && !app.bundleId.lowercased().hasPrefix("com.apple.")
    }

    func trashDirectly(_ app: InstalledApp) {
        guard Self.canTrashDirectly(app) else {
            fallbackMessage = "\(app.name) bu yolla taşınamaz."
            return
        }
        let url = URL(fileURLWithPath: app.path)
        let size = app.sizeBytes
        NSWorkspace.shared.recycle([url]) { trashed, error in
            Task { @MainActor in
                let log = OperationLog(command: "uninstall")
                if error == nil, !trashed.isEmpty, !FileManager.default.fileExists(atPath: url.path) {
                    log.recordTrash(path: url.path, sizeBytes: size, succeeded: true)
                    self.fallbackMessage = "\(app.name) Çöp Sepeti'ne taşındı. Kalan artıkları Akıllı Temizlik bulur."
                    self.load()
                } else {
                    log.recordTrash(path: url.path, sizeBytes: size, succeeded: false)
                    self.fallbackMessage = "macOS \(app.name) için de izin vermedi: \(error?.localizedDescription ?? "bilinmeyen hata")"
                }
            }
        }
    }

    func toggle(_ app: InstalledApp) {
        if selection.contains(app.id) {
            selection.remove(app.id)
        } else {
            selection.insert(app.id)
        }
    }
}
