import Foundation

/// A mounted disk the user can move files to: writable, local and not one of
/// the Mac's internal volumes.
struct ExternalVolume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// `nil` when macOS does not say.
    let isEncrypted: Bool?
    let availableBytes: Int64
    let totalBytes: Int64

    var id: String { url.path }

    static func mounted() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
            .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsEncryptedKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsEjectableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  // Card readers and disk images leave "internal" unanswered;
                  // they count when macOS can eject them.
                  values.volumeIsInternal == false || (values.volumeIsInternal == nil && values.volumeIsEjectable == true),
                  values.volumeIsLocal == true,
                  values.volumeIsReadOnly != true,
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsBrowsable != false
            else { return nil }
            return ExternalVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isEncrypted: values.volumeIsEncrypted,
                availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                totalBytes: Int64(values.volumeTotalCapacity ?? 0)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func availableBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let bytes = values.volumeAvailableCapacity else { return nil }
        return Int64(bytes)
    }
}

/// Copy, byte-for-byte check, then Trash: the pieces of "move to an external
/// disk", kept free of UI so they can be tested.
enum SafeMove {
    enum Problem: Equatable, Sendable {
        case sourceMissing
        case destinationFolderMissing
        case destinationExists(String)
        case sameVolume
        case nested
        case notEnoughSpace(needed: Int64, available: Int64)

        var message: String {
            switch self {
            case .sourceMissing:
                return "Seçtiğiniz öğe artık yerinde değil."
            case .destinationFolderMissing:
                return "Hedef klasör bulunamadı. Disk çıkarılmış olabilir."
            case let .destinationExists(path):
                return "Hedefte aynı adlı bir öğe var: \(path). Üzerine yazmamak için durduruldu; adını değiştirin ya da başka bir klasör seçin."
            case .sameVolume:
                return "Kaynak ve hedef aynı diskte. Taşıma yalnızca başka bir diske yapılır."
            case .nested:
                return "Hedef, taşınacak klasörün içinde (ya da tersi)."
            case let .notEnoughSpace(needed, available):
                return "Diskte yeterli yer yok: \(TextUtils.formatBytes(needed)) gerekiyor, \(TextUtils.formatBytes(available)) boş."
            }
        }
    }

    /// Where the copy of `source` lands inside `folder`.
    static func destination(for source: URL, in folder: URL) -> URL {
        folder.appendingPathComponent(source.lastPathComponent, isDirectory: false)
    }

    /// Everything that must hold before a single byte is copied.
    static func preflight(source: URL, folder: URL, sourceBytes: Int64, availableBytes: Int64?) -> [Problem] {
        let fm = FileManager.default
        var problems: [Problem] = []
        let sourcePath = source.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        guard fm.fileExists(atPath: sourcePath) || (try? fm.destinationOfSymbolicLink(atPath: sourcePath)) != nil else {
            return [.sourceMissing]
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            return [.destinationFolderMissing]
        }
        let target = destination(for: source, in: folder).path
        if fm.fileExists(atPath: target) || (try? fm.destinationOfSymbolicLink(atPath: target)) != nil {
            problems.append(.destinationExists(target))
        }
        if folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
            problems.append(.nested)
        }
        if let a = volumeID(source), let b = volumeID(folder), a.isEqual(b) {
            problems.append(.sameVolume)
        }
        // Keep a little room so the disk is not filled to the last byte.
        let margin: Int64 = 200_000_000
        if let availableBytes, sourceBytes + margin > availableBytes {
            problems.append(.notEnoughSpace(needed: sourceBytes + margin, available: availableBytes))
        }
        return problems
    }

    private static func volumeID(_ url: URL) -> NSObjectProtocol? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObjectProtocol
    }

    /// Copies with `/usr/bin/ditto`, which keeps permissions, dates, extended
    /// attributes and resource forks. Refuses to touch an existing target.
    static func copy(from source: URL, to target: URL) async throws {
        if FileManager.default.fileExists(atPath: target.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
            throw CommandError.failed(status: 1, message: Problem.destinationExists(target.path).message)
        }
        let result = try await CommandRunner.run("/usr/bin/ditto", [source.path, target.path])
        guard result.succeeded else {
            throw CommandError.failed(status: result.status, message: result.stderr)
        }
    }

    struct VerifyReport: Equatable, Sendable {
        var files = 0
        var folders = 0
        var links = 0
        var bytes: Int64 = 0
        var missing = 0
        var different = 0
        var unreadable = 0
        /// Up to 20 relative paths that did not match, for the user to see.
        var examples: [String] = []

        var isIdentical: Bool { missing == 0 && different == 0 && unreadable == 0 && files + folders + links > 0 }

        mutating func note(_ path: String) {
            if examples.count < 20 { examples.append(path) }
        }
    }

    /// Compares every item under `source` with its twin under `copy`, file
    /// contents byte for byte. `progress` receives the bytes compared so far.
    /// The walk lists folders itself (never following symlinks), so broken
    /// links and hidden files are checked too.
    static func verify(source: URL, copy: URL, progress: (@Sendable (Int64) -> Void)? = nil) throws -> VerifyReport {
        var report = VerifyReport()
        let fm = FileManager.default

        func type(_ path: String) -> FileAttributeType? {
            (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        }

        func compare(relative: String, from a: String, to b: String) throws {
            try Task.checkCancellation()
            guard let kind = type(a) else {
                report.unreadable += 1
                report.note(relative)
                return
            }
            let twinKind = type(b)
            switch kind {
            case .typeSymbolicLink:
                report.links += 1
                guard let original = try? fm.destinationOfSymbolicLink(atPath: a) else {
                    report.unreadable += 1
                    report.note(relative)
                    return
                }
                guard twinKind == .typeSymbolicLink, let twin = try? fm.destinationOfSymbolicLink(atPath: b) else {
                    if twinKind == nil { report.missing += 1 } else { report.different += 1 }
                    report.note(relative)
                    return
                }
                if original != twin {
                    report.different += 1
                    report.note(relative)
                }
            case .typeDirectory:
                report.folders += 1
                guard twinKind == .typeDirectory else {
                    if twinKind == nil { report.missing += 1 } else { report.different += 1 }
                    report.note(relative)
                    return
                }
                guard let children = try? fm.contentsOfDirectory(atPath: a) else {
                    report.unreadable += 1
                    report.note(relative)
                    return
                }
                for child in children.sorted() {
                    try compare(relative: relative + "/" + child,
                                from: (a as NSString).appendingPathComponent(child),
                                to: (b as NSString).appendingPathComponent(child))
                }
            case .typeRegular:
                report.files += 1
                guard twinKind == .typeRegular else {
                    if twinKind == nil { report.missing += 1 } else { report.different += 1 }
                    report.note(relative)
                    return
                }
                switch sameContents(URL(fileURLWithPath: a), URL(fileURLWithPath: b)) {
                case .same(let size):
                    report.bytes += size
                    progress?(report.bytes)
                case .different:
                    report.different += 1
                    report.note(relative)
                case .unreadable:
                    report.unreadable += 1
                    report.note(relative)
                }
            default:
                // Sockets, pipes and devices have no contents to compare.
                if twinKind == nil {
                    report.missing += 1
                    report.note(relative)
                }
            }
        }

        try compare(relative: source.lastPathComponent, from: source.path, to: copy.path)
        return report
    }

    enum Comparison { case same(Int64), different, unreadable }

    static func sameContents(_ a: URL, _ b: URL) -> Comparison {
        guard let left = try? FileHandle(forReadingFrom: a) else { return .unreadable }
        defer { try? left.close() }
        guard let right = try? FileHandle(forReadingFrom: b) else { return .different }
        defer { try? right.close() }
        let chunk = 4 * 1024 * 1024
        var total: Int64 = 0
        while true {
            let outcome: Comparison? = autoreleasepool {
                // read(upToCount:) answers nil or empty data at the end.
                let x: Data
                let y: Data
                do { x = try left.read(upToCount: chunk) ?? Data() } catch { return .unreadable }
                do { y = try right.read(upToCount: chunk) ?? Data() } catch { return .different }
                if x != y { return .different }
                if x.isEmpty { return .same(total) }
                total += Int64(x.count)
                return nil
            }
            if let outcome { return outcome }
        }
    }
}
