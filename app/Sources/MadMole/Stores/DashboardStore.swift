import Foundation
import Observation

/// Streams `status-go --watch` NDJSON while the dashboard is on screen.
@MainActor
@Observable
final class DashboardStore {
    private(set) var snapshot: StatusSnapshot?
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var errorMessage: String?
    private(set) var isStreaming = false
    private var task: Task<Void, Never>?
    private let historyLength = 90

    func start() {
        guard task == nil else { return }
        isStreaming = true
        errorMessage = nil
        task = Task {
            await self.stream()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    private func stream() async {
        let decoder = JSONDecoder.engine
        do {
            let stream = CommandRunner.lines(Engine.statusBinary, ["--watch", "--interval", "2s"])
            for try await line in stream {
                if Task.isCancelled { break }
                guard let data = line.data(using: .utf8), !data.isEmpty,
                      let value = try? decoder.decode(StatusSnapshot.self, from: data) else { continue }
                apply(value)
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        if !Task.isCancelled {
            isStreaming = false
            task = nil
        }
    }

    private func apply(_ value: StatusSnapshot) {
        snapshot = value
        if let usage = value.cpu?.usage {
            cpuHistory.append(usage)
            if cpuHistory.count > historyLength { cpuHistory.removeFirst(cpuHistory.count - historyLength) }
        }
        if let used = value.memory?.usedPercent {
            memoryHistory.append(used)
            if memoryHistory.count > historyLength { memoryHistory.removeFirst(memoryHistory.count - historyLength) }
        }
    }
}
