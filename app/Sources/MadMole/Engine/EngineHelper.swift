import Foundation

/// Talks to `madmole-helper.sh`, so every safety decision the new screens
/// need comes from the engine itself: the protected-path list
/// (`~/.config/mole/whitelist`), `validate_path_for_deletion`, the
/// `mole_delete` Trash funnel with its operations.log rows, the uninstall
/// inventory (`find_app_files`) and the orphan rules of `mo clean`.
struct EngineHelper: Sendable {
    var script: String = Engine.helperScript
    var engineRoot: String = Engine.rootURL.path
    /// Tests pass a fixture HOME and Trash; the app uses the engine's normal
    /// environment.
    var environment: [String: String]?

    enum Verdict: Equatable, Sendable {
        case allowed
        case refused(reason: String)
        case failed(status: String)
    }

    struct PathResult: Equatable, Sendable {
        let path: String
        let verdict: Verdict
    }

    private func run(_ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        try await CommandRunner.run("/bin/bash", [script, engineRoot] + arguments,
                                    environment: environment, onLine: onLine)
    }

    /// Asks whether each path may be removed, without changing anything.
    func check(_ paths: [String]) async throws -> [PathResult] {
        guard !paths.isEmpty else { return [] }
        let result = try await run(["check"] + paths)
        guard result.succeeded else { throw CommandError.failed(status: result.status, message: result.stderr) }
        return Self.parsePathResults(result.output)
    }

    /// Moves the paths to the Trash through `mole_delete`; nothing is ever
    /// removed permanently. `command` names the operations.log session.
    func trash(_ paths: [String], command: String) async throws -> [PathResult] {
        guard !paths.isEmpty else { return [] }
        let result = try await run(["trash", command] + paths)
        guard result.succeeded else { throw CommandError.failed(status: result.status, message: result.stderr) }
        return Self.parsePathResults(result.output)
    }

    struct AppQuery: Sendable {
        let bundleId: String
        let name: String
        let path: String
    }

    /// The user files the uninstall inventory attributes to each app.
    /// `onApp` runs as each app finishes, with its index in `apps`.
    func appFiles(_ apps: [AppQuery], onApp: @escaping @Sendable (Int, [String]) -> Void) async throws {
        guard !apps.isEmpty else { return }
        let collector = AppFilesCollector(onApp: onApp)
        let arguments = apps.flatMap { [$0.bundleId.isEmpty ? "unknown" : $0.bundleId, $0.name, $0.path] }
        let result = try await run(["appfiles"] + arguments) { line in collector.consume(line) }
        guard result.succeeded else { throw CommandError.failed(status: result.status, message: result.stderr) }
    }

    struct OrphanReport: Sendable {
        var installedBundles: Set<String> = []
        /// orphan, keep, unknown (reverse-DNS ids) or name, keep (other names).
        var verdicts: [String: String] = [:]
    }

    /// The engine's view of which candidate folders have no installed app.
    /// Throws when the installed-app scan fails: without a complete list no
    /// folder may be called orphaned.
    func orphans(_ candidates: [(id: String, path: String)]) async throws -> OrphanReport {
        let result = try await run(["orphans"] + candidates.flatMap { [$0.id, $0.path] })
        guard result.succeeded else { throw CommandError.failed(status: result.status, message: result.stderr) }
        return Self.parseOrphanReport(result.output)
    }

    // MARK: Parsing

    static func parsePathResults(_ output: String) -> [PathResult] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch (fields.first, fields.count) {
            case ("ok", 2): return PathResult(path: fields[1], verdict: .allowed)
            case ("refused", 3): return PathResult(path: fields[2], verdict: .refused(reason: fields[1]))
            case ("failed", 3): return PathResult(path: fields[2], verdict: .failed(status: fields[1]))
            default: return nil
            }
        }
    }

    static func parseOrphanReport(_ output: String) -> OrphanReport {
        var report = OrphanReport()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, !fields[1].isEmpty else { continue }
            if fields[0] == "installed" {
                report.installedBundles.insert(fields[1])
            } else {
                report.verdicts[fields[1]] = fields[0]
            }
        }
        return report
    }

    /// Plain-language reason for a refusal code from the helper.
    static func describe(reason: String) -> String {
        switch reason {
        case "whitelist": return "korunan yollar listenizde"
        case "contains-whitelisted": return "içinde korunan bir yol var"
        case "missing": return "artık yerinde değil"
        case "not-absolute": return "geçersiz yol"
        case "protected": return "motorun korunan sistem yollarından"
        case "live user cache": return "açık bir uygulama şu an kullanıyor"
        default: return reason
        }
    }
}

/// Groups `appfiles` lines by app; "INDEX<TAB>" closes one app.
private final class AppFilesCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: [String]] = [:]
    private let onApp: @Sendable (Int, [String]) -> Void

    init(onApp: @escaping @Sendable (Int, [String]) -> Void) {
        self.onApp = onApp
    }

    func consume(_ line: String) {
        let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, let index = Int(fields[0]) else { return }
        let path = String(fields[1])
        lock.lock()
        if path.isEmpty {
            let files = pending.removeValue(forKey: index) ?? []
            lock.unlock()
            onApp(index, files)
        } else {
            pending[index, default: []].append(path)
            lock.unlock()
        }
    }
}

/// Bytes a file or folder occupies on disk, without following symlinks.
enum DiskUsage {
    /// Drops paths that sit inside another listed path, so nothing counts twice.
    static func outermost(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
        var result: [String] = []
        for path in unique where !result.contains(where: { path.hasPrefix($0 + "/") }) {
            result.append(path)
        }
        return result
    }

    static func allocatedSize(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
