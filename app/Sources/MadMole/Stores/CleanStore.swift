import Foundation
import Observation

/// Runs `mole clean --dry-run` without a terminal and reads the candidate list
/// the engine writes. The real cleanup runs in the terminal sheet so the
/// engine's own administrator prompt and safety checks stay in charge.
@MainActor
@Observable
final class CleanStore {
    enum Phase {
        case idle
        case scanning
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var preview: CleanPreview?
    private(set) var lastLine = ""
    private(set) var startedAt: Date?
    private(set) var lastScan: Date?
    /// When the engine last printed anything; drives the "no output for a
    /// while" hint on the scanning screen.
    private(set) var lastActivity: Date?

    /// One `PERF [label] 1.234s` timing the engine writes in --debug runs.
    struct PerfEntry: Identifiable {
        let id = UUID()
        let label: String
        let seconds: Double
    }

    /// The slowest steps of the last verbose scan, slowest first.
    private(set) var perfReport: [PerfEntry] = []
    private(set) var lastScanDuration: TimeInterval?

    static var debugLog: URL {
        Engine.logDirectory.appendingPathComponent("mole_debug_session.log")
    }
    private(set) var systemPreviewIncluded = false
    var console: ConsoleLog?
    private var task: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func scan(verbose: Bool = false) {
        guard !isScanning else { return }
        let arguments = ["clean", "--dry-run"] + (verbose ? ["--debug"] : [])
        if verbose { console?.isVisible = true }
        perfReport = []
        let debugOffset = verbose ? Self.fileSize(Self.debugLog) : nil
        phase = .scanning
        lastLine = ""
        let started = Date()
        startedAt = started
        lastActivity = started
        systemPreviewIncluded = false
        console?.append("mo " + arguments.joined(separator: " "), source: "clean")
        let consoleSink = console?.sink(source: "clean")
        task = Task {
            do {
                let result = try await CommandRunner.mole(arguments) { line in
                    consoleSink?(line)
                    Task { @MainActor in self.noteLine(line) }
                }
                self.finish(result: result, startedAt: started)
                self.lastScanDuration = Date().timeIntervalSince(started)
                if let debugOffset {
                    self.perfReport = Self.perfEntries(since: debugOffset)
                }
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = preview == nil ? .idle : .loaded
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Reads the PERF timings appended to the debug log after `offset`.
    static func perfEntries(since offset: UInt64) -> [PerfEntry] {
        guard let handle = try? FileHandle(forReadingFrom: debugLog) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var entries: [PerfEntry] = []
        for line in text.split(separator: "\n") {
            guard let start = line.range(of: "PERF ["),
                  let close = line.range(of: "] ", range: start.upperBound..<line.endIndex) else { continue }
            let label = String(line[start.upperBound..<close.lowerBound])
            let rest = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            guard rest.hasSuffix("s"), let seconds = Double(rest.dropLast()) else { continue }
            entries.append(PerfEntry(label: label, seconds: seconds))
        }
        return entries.sorted { $0.seconds > $1.seconds }
    }

    /// A short plain-text report of the slowest steps, to paste into a message.
    var perfReportText: String {
        var lines = ["MadMole ayrıntılı tarama"]
        if let duration = lastScanDuration {
            lines.append("Toplam süre: \(Int(duration)) sn")
        }
        lines.append("En yavaş adımlar:")
        for (index, entry) in perfReport.prefix(20).enumerated() {
            lines.append(String(format: "%2d. %@ — %.1f sn", index + 1, entry.label, entry.seconds))
        }
        return lines.joined(separator: "\n")
    }

    private func noteLine(_ line: String) {
        let text = TextUtils.stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        lastActivity = Date()
        guard !TextUtils.isDecoration(text) else { return }
        lastLine = text
        if text.contains("system preview included") {
            systemPreviewIncluded = true
        }
    }

    private func finish(result: CommandResult, startedAt: Date) {
        task = nil
        if Task.isCancelled {
            phase = preview == nil ? .idle : .loaded
            return
        }
        guard result.succeeded else {
            phase = .failed(CommandError.failed(status: result.status, message: result.stderr.isEmpty ? lastLine : result.stderr).localizedDescription)
            return
        }
        let file = Engine.cleanPreviewFile
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let modified, modified >= startedAt.addingTimeInterval(-2) else {
            // Nothing to clean leaves no fresh list behind.
            preview = CleanPreview(sections: [], generatedAt: Date())
            lastScan = Date()
            phase = .loaded
            return
        }
        var parsed = CleanPreview.parse(text)
        parsed.generatedAt = modified
        preview = parsed
        lastScan = Date()
        phase = .loaded
    }
}
