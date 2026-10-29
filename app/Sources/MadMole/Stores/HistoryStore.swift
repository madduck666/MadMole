import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {
    private(set) var log: HistoryLog?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await CommandRunner.mole(["history", "--json", "--limit", "200"])
                guard result.succeeded else {
                    throw CommandError.failed(status: result.status, message: result.stderr)
                }
                self.log = try JSONDecoder.engine.decode(HistoryLog.self, from: result.stdout)
            } catch is DecodingError {
                self.errorMessage = CommandError.decoding("geçmiş").localizedDescription
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }
}
