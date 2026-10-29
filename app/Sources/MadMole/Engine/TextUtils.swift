import Foundation

enum TextUtils {
    private static let ansiPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[()][A-Za-z0-9]|\u{1B}[=>78]",
        options: []
    )

    /// Removes terminal escape sequences and carriage-return redraws so engine
    /// output reads as plain text.
    static func stripANSI(_ text: String) -> String {
        var value = text
        if let regex = ansiPattern {
            let range = NSRange(value.startIndex..., in: value)
            value = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: "")
        }
        // A spinner redraws a line with \r; keep only what the line ended as.
        if value.contains("\r") {
            value = value.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? value
        }
        return value
    }

    /// Parses the engine's human sizes ("1.23GB", "512KB", "40B", "1.5 MB").
    /// Mole uses decimal units, matching Finder.
    static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty else { return nil }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count)
            guard let value = Double(number) else { return nil }
            return Int64(value * factor)
        }
        return Int64(trimmed)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        formatBytes(Int64(clamping: bytes))
    }

    static func formatRate(_ megabytesPerSecond: Double) -> String {
        if megabytesPerSecond >= 1 {
            return String(format: "%.1f MB/s", megabytesPerSecond)
        }
        return String(format: "%.0f KB/s", megabytesPerSecond * 1000)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// Shortens a path under the home directory to `~/...`.
    static func abbreviatePath(_ path: String) -> String {
        let home = Engine.homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
