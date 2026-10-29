import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String

    var output: String { String(decoding: stdout, as: UTF8.self) }
    var succeeded: Bool { status == 0 }
}

enum CommandError: LocalizedError {
    case engineMissing
    case failed(status: Int32, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .engineMissing:
            return "Mole motoru uygulama paketinde bulunamadı. Uygulamayı scripts/build_app.sh ile yeniden derleyin."
        case let .failed(status, message):
            let detail = TextUtils.stripANSI(message).trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Komut \(status) koduyla sonlandı." : detail
        case let .decoding(message):
            return "Motor çıktısı okunamadı: \(message)"
        }
    }
}

/// Holds mutable state shared between the reader threads of one process.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var pending = Data()

    func appendStdout(_ data: Data, lineHandler: (@Sendable (String) -> Void)?) {
        var lines: [String] = []
        lock.lock()
        stdout.append(data)
        if lineHandler != nil {
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                lines.append(String(decoding: lineData, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        lock.unlock()
        if let lineHandler {
            for line in lines { lineHandler(line) }
        }
    }

    func flushPending(lineHandler: (@Sendable (String) -> Void)?) {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        if let lineHandler, !rest.isEmpty {
            lineHandler(String(decoding: rest, as: UTF8.self))
        }
    }

    func setStderr(_ data: Data) {
        lock.lock()
        stderr = data
        lock.unlock()
    }

    func result(status: Int32) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        return CommandResult(status: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }
}

/// Wraps a Process so cancellation handlers can reach it.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

enum CommandRunner {
    /// Runs one engine command without a terminal (stdin is /dev/null), so the
    /// engine takes its non-interactive, read-only paths. Cancelling the task
    /// terminates the process.
    static func run(
        _ executable: String,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError.engineMissing
        }
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Engine.environment(terminal: false)
        process.currentDirectoryURL = URL(fileURLWithPath: Engine.homeDirectory, isDirectory: true)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let buffer = OutputBuffer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        buffer.setStderr(data)
                        group.leave()
                    }
                    let handle = outPipe.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer.appendStdout(chunk, lineHandler: onLine)
                    }
                    buffer.flushPending(lineHandler: onLine)
                    group.wait()
                    process.waitUntilExit()
                    continuation.resume(returning: buffer.result(status: process.terminationStatus))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Runs the bundled `mole` router.
    static func mole(_ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        try await run(Engine.mole, arguments, onLine: onLine)
    }

    /// Streams stdout lines of a long-running command (for example
    /// `status-go --watch`). Ending the stream terminates the process.
    static func lines(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                continuation.finish(throwing: CommandError.engineMissing)
                return
            }
            let box = ProcessBox()
            let process = box.process
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = Engine.environment(terminal: false)
            process.currentDirectoryURL = URL(fileURLWithPath: Engine.homeDirectory, isDirectory: true)
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let buffer = OutputBuffer()
            let lineHandler: @Sendable (String) -> Void = { line in
                continuation.yield(line)
            }
            continuation.onTermination = { _ in
                box.terminate()
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let handle = outPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.appendStdout(chunk, lineHandler: lineHandler)
                }
                buffer.flushPending(lineHandler: lineHandler)
                process.waitUntilExit()
                let status = process.terminationStatus
                if status == 0 || status == SIGTERM || process.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: CommandError.failed(status: status, message: ""))
                }
            }
        }
    }
}
