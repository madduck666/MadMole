import Foundation

/// The candidate list `mole clean --dry-run` writes to
/// `~/.config/mole/clean-list.txt`:
///
///     === Section ===
///     /path  # 1.23GB, 3 items
///     /path  # size unknown, counted under /parent
struct CleanPreview {
    struct Item: Identifiable, Hashable {
        let path: String
        let sizeBytes: Int64?
        let itemCount: Int
        let coveredBy: String?
        var id: String { path }
    }

    struct Section: Identifiable {
        let name: String
        var items: [Item]
        var id: String { name }

        /// Bytes this section adds to the total; rows inside another measured
        /// row are already counted there.
        var countedBytes: Int64 {
            items.filter { $0.coveredBy == nil }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        }

        var countedItems: Int {
            items.filter { $0.coveredBy == nil }.reduce(0) { $0 + $1.itemCount }
        }
    }

    var sections: [Section]
    var generatedAt: Date?

    var totalBytes: Int64 { sections.reduce(0) { $0 + $1.countedBytes } }
    var totalItems: Int { sections.reduce(0) { $0 + $1.countedItems } }
    var hasUnknownSizes: Bool {
        sections.contains { $0.items.contains { $0.sizeBytes == nil && $0.coveredBy == nil } }
    }

    static func parse(_ text: String) -> CleanPreview {
        var sections: [Section] = []
        var current: Section?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                if let section = current { sections.append(section) }
                let name = String(line.dropFirst(4).dropLast(4))
                current = Section(name: name, items: [])
                continue
            }
            guard let item = parseItem(line) else { continue }
            if current == nil { current = Section(name: "Diğer", items: []) }
            current?.items.append(item)
        }
        if let section = current { sections.append(section) }

        // A section name can repeat when the engine revisits it; merge them.
        var merged: [Section] = []
        for section in sections {
            if let index = merged.firstIndex(where: { $0.name == section.name }) {
                merged[index].items.append(contentsOf: section.items)
            } else {
                merged.append(section)
            }
        }
        return CleanPreview(sections: merged.filter { !$0.items.isEmpty }, generatedAt: nil)
    }

    private static func parseItem(_ line: String) -> Item? {
        guard let marker = line.range(of: "  # ", options: .backwards) else {
            return Item(path: line, sizeBytes: nil, itemCount: 1, coveredBy: nil)
        }
        let path = String(line[..<marker.lowerBound])
        let detail = String(line[marker.upperBound...])
        var size: Int64?
        var count = 1
        var coveredBy: String?

        for part in detail.components(separatedBy: ", ") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece == "size unknown" {
                size = nil
            } else if piece.hasSuffix(" items"), let value = Int(piece.dropLast(" items".count)) {
                count = value
            } else if piece.hasPrefix("counted under ") {
                coveredBy = String(piece.dropFirst("counted under ".count))
            } else if let bytes = TextUtils.parseSize(piece) {
                size = bytes
            }
        }
        return Item(path: path, sizeBytes: size, itemCount: count, coveredBy: coveredBy)
    }
}
