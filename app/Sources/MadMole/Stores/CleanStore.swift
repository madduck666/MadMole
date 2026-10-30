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
    private(set) var systemPreviewIncluded = false
    var console: ConsoleLog?
    private var task: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func scan() {
        guard !isScanning else { return }
        phase = .scanning
        lastLine = ""
        let started = Date()
        startedAt = started
        lastActivity = started
        systemPreviewIncluded = false
        console?.append("mo clean --dry-run", source: "clean")
        let consoleSink = console?.sink(source: "clean")
        task = Task {
            do {
                let result = try await CommandRunner.mole(["clean", "--dry-run"]) { line in
                    consoleSink?(line)
                    Task { @MainActor in self.noteLine(line) }
                }
                self.finish(result: result, startedAt: started)
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
