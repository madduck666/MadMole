import Foundation

/// Writes Trash moves the app makes itself into the engine's logs, in the
/// shared format `mo history`, Mole Mac and the support diagnostic read:
/// a session in operations.log and one deletions.log TSV row per item
/// (mirrors cmd/analyze/oplog.go).
struct OperationLog {
    let command: String
    private let runID: String

    init(command: String) {
        self.command = command
        let stamp = OperationLog.digits(Date())
        runID = "\(stamp)-\(ProcessInfo.processInfo.processIdentifier)-\(Int.random(in: 0...32767))-\(Int.random(in: 0...32767))"
    }

    private var field: String { "\(command) run=\(runID)" }

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MO_NO_OPLOG"] != "1"
    }

    private static func digits(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    private static func stamp(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }

    /// Control bytes become \n, \r, \t or \xHH so a name cannot forge a record.
    static func escape(_ value: String) -> String {
        var bytes: [UInt8] = []
        for byte in value.utf8 {
            switch byte {
            case 0x0A: bytes += Array("\\n".utf8)
            case 0x0D: bytes += Array("\\r".utf8)
            case 0x09: bytes += Array("\\t".utf8)
            case 0..<0x20, 0x7F: bytes += Array(String(format: "\\x%02x", byte).utf8)
            default: bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// bytes_to_human from lib/core/base.sh.
    static func sizeText(_ bytes: Int64) -> String {
        switch bytes {
        case 1_000_000_000...:
            let scaled = (bytes * 100 + 500_000_000) / 1_000_000_000
            return String(format: "%lld.%02lldGB", scaled / 100, scaled % 100)
        case 1_000_000...:
            let scaled = (bytes * 10 + 500_000) / 1_000_000
            return String(format: "%lld.%01lldMB", scaled / 10, scaled % 10)
        case 1000...:
            return "\((bytes + 500) / 1000)KB"
        default:
            return "\(max(bytes, 0))B"
        }
    }

    private static func append(_ lines: [String], to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file)
            }
        } catch {
            // Logging must never block the action it records.
        }
    }

    /// Records one finished Trash move (or its failure) as its own session.
    func recordTrash(path: String, sizeBytes: Int64, succeeded: Bool, reason: String = "trash-failed") {
        guard Self.enabled else { return }
        let operations = Engine.logDirectory.appendingPathComponent("operations.log")
        let deletions = Engine.logDirectory.appendingPathComponent("deletions.log")
        let time = Self.stamp("yyyy-MM-dd HH:mm:ss")
        var row = "[\(time)] [\(field)] "
        if succeeded {
            row += "TRASHED \(Self.escape(path))" + (sizeBytes > 0 ? " (\(Self.sizeText(sizeBytes)))" : "")
        } else {
            row += "FAILED \(Self.escape(path)) (\(reason))"
        }
        Self.append([
            "",
            "# ========== \(field) session started at \(time) ==========",
            row,
            "# ========== \(field) session ended at \(Self.stamp("yyyy-MM-dd HH:mm:ss")), \(succeeded ? 1 : 0) items, \(Self.sizeText(succeeded ? sizeBytes : 0)) ==========",
        ], to: operations)
        let sizeKB = (max(sizeBytes, 0) + 1023) / 1024
        Self.append([
            [Self.stamp("yyyy-MM-dd'T'HH:mm:ssZ"), "trash", "\(sizeKB)", succeeded ? "ok" : "trash-failed", Self.escape(path)]
                .joined(separator: "\t"),
        ], to: deletions)
    }
}

/// Reads the rows the engine appended to deletions.log during one run.
enum DeletionsLog {
    struct Row {
        let status: String
        let path: String
    }

    static var file: URL { Engine.logDirectory.appendingPathComponent("deletions.log") }

    /// The current end of the log; pass it to `rows(since:)` after a run.
    static func currentOffset() -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func rows(since offset: UInt64) -> [Row] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                // timestamp, mode, size_kb, status, path
                let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                guard fields.count == 5 else { return nil }
                return Row(status: String(fields[3]), path: String(fields[4]))
            }
    }
}
