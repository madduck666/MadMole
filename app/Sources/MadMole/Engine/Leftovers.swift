import Foundation

/// One suggested leftover: data whose app is gone, an unfinished update, or a
/// login item whose program no longer exists. Suggestions only; nothing is
/// selected by default and removal always goes to the Trash.
struct Leftover: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case appData = "Sahibi kaldırılmış veri"
        case nameOnly = "Muhtemel artık (adına göre)"
        case launchItem = "Açılış kaydı"
        case partialUpdate = "Yarım kalmış güncelleme"
        case sparkle = "Sparkle güncelleme artığı"

        var explanation: String {
            switch self {
            case .appData:
                return "Klasörün adı bir uygulama kimliği; motor bu kimlikte yüklü bir uygulama bulamadı ve klasör 30 günden uzun süredir değişmedi."
            case .nameOnly:
                return "Kimlik değil, düz bir ad. İçinde bir program var ama o adla yüklü bir uygulama yok. Seçmeden önce adına bakın."
            case .launchItem:
                return "Oturum açınca çalışan bir kayıt; çalıştırdığı program artık yok ya da sahipsiz bir klasörün içinde."
            case .partialUpdate:
                return "Adı .install ile biten, 7 günden eski bir kurulum klasörü."
            case .sparkle:
                return "Sparkle güncelleyicisinin Uygulamalar klasöründe bıraktığı geçici klasör."
            }
        }
    }

    let path: String
    let kind: Kind
    let location: String
    var sizeBytes: Int64 = 0
    var modified: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Finds leftover candidates on disk. The engine (`madmole-helper.sh
/// orphans`) has the last word on which app-data folders are orphaned; this
/// type only lists folders and applies the extra evidence rules.
struct LeftoverScanner: Sendable {
    var home: String = Engine.homeDirectory
    var applicationFolders: [String] = ["/Applications", Engine.homeDirectory + "/Applications"]
    var now = Date()

    /// Folders whose children are app data named after the app.
    static let dataFolders = [
        "Library/Application Support",
        "Library/Containers",
        "Library/Caches",
        "Library/HTTPStorages",
        "Library/WebKit",
        "Library/Application Scripts",
        "Library/Saved Application State",
    ]

    static let ageLimit: TimeInterval = 30 * 86_400
    static let installAgeLimit: TimeInterval = 7 * 86_400
    static let sparkleAgeLimit: TimeInterval = 86_400

    struct Candidate: Hashable, Sendable {
        let id: String
        let path: String
        let location: String
    }

    /// Every child of the data folders, with the id the engine judges it by.
    func dataCandidates() -> [Candidate] {
        var list: [Candidate] = []
        for folder in Self.dataFolders {
            let base = (home as NSString).appendingPathComponent(folder)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for name in names where !name.hasPrefix(".") {
                var id = name
                if id.hasSuffix(".savedState") { id = String(id.dropLast(".savedState".count)) }
                if id.lowercased().hasPrefix("com.apple.") { continue }
                list.append(Candidate(id: id, path: (base as NSString).appendingPathComponent(name),
                                      location: (folder as NSString).lastPathComponent))
            }
        }
        return list
    }

    /// Lowercased names of installed apps, without ".app".
    func installedAppNames() -> Set<String> {
        var names: Set<String> = []
        let roots = applicationFolders + ["/System/Applications"]
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for child in children {
                if child.hasSuffix(".app") {
                    names.insert(Self.normalize(String(child.dropLast(4))))
                } else if !child.hasPrefix("."),
                          let nested = try? FileManager.default.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(child)) {
                    for app in nested where app.hasSuffix(".app") {
                        names.insert(Self.normalize(String(app.dropLast(4))))
                    }
                }
            }
        }
        return names
    }

    static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Applies the engine's verdicts plus the extra evidence rules and
    /// returns the suggested app-data leftovers.
    func appData(candidates: [Candidate], report: EngineHelper.OrphanReport) -> [Leftover] {
        let installedNames = installedAppNames()
        let installedLower = Set(report.installedBundles.map { $0.lowercased() })
        // Tokens from installed bundle ids: "com.valvesoftware.steam" gives
        // "valvesoftware" and "steam". A plain-named folder matching one of
        // them belongs to an installed vendor or app.
        var tokens: Set<String> = []
        for bundle in installedLower {
            for part in bundle.split(separator: ".") where part.count >= 3 {
                tokens.insert(Self.normalize(String(part)))
            }
        }
        var result: [Leftover] = []
        for candidate in candidates {
            let verdict = report.verdicts[candidate.path]
            let modified = Self.modified(candidate.path)
            switch verdict {
            case "orphan":
                // An extension or helper of an installed app carries the
                // app's id as a prefix (com.vendor.app.ShareExtension).
                let lower = candidate.id.lowercased()
                if installedLower.contains(where: { lower.hasPrefix($0 + ".") }) { continue }
                result.append(Leftover(path: candidate.path, kind: .appData, location: candidate.location, modified: modified))
            case "name":
                let key = Self.normalize(candidate.id)
                guard key.count >= 3, !installedNames.contains(key), !tokens.contains(key) else { continue }
                guard let modified, now.timeIntervalSince(modified) >= Self.ageLimit else { continue }
                guard Self.containsProgram(candidate.path) else { continue }
                result.append(Leftover(path: candidate.path, kind: .nameOnly, location: candidate.location, modified: modified))
            default:
                continue
            }
        }
        return result
    }

    /// A folder that holds a program: an `.app`, a Steam-style `.AppBundle`,
    /// or any `Contents/MacOS` within three levels.
    static func containsProgram(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return false }
        for case let item as URL in enumerator {
            if enumerator.level > 3 {
                enumerator.skipDescendants()
                continue
            }
            let ext = item.pathExtension.lowercased()
            if ext == "app" || ext == "appbundle" { return true }
            if item.lastPathComponent == "MacOS", item.deletingLastPathComponent().lastPathComponent == "Contents" { return true }
        }
        return false
    }

    /// `~/Library/LaunchAgents` plists whose program is missing or lives
    /// inside one of `orphanFolders`. A plist that names no program, or whose
    /// program exists elsewhere, is never suggested.
    func launchItems(orphanFolders: [String]) -> [Leftover] {
        let base = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        var result: [Leftover] = []
        for name in names where name.hasSuffix(".plist") && !name.lowercased().hasPrefix("com.apple.") {
            let path = (base as NSString).appendingPathComponent(name)
            guard let program = Self.launchProgram(path), program.hasPrefix("/") else { continue }
            let missing = !FileManager.default.fileExists(atPath: program)
            let insideOrphan = orphanFolders.contains { program.hasPrefix($0 + "/") }
            if missing || insideOrphan {
                result.append(Leftover(path: path, kind: .launchItem, location: "LaunchAgents", modified: Self.modified(path)))
            }
        }
        return result
    }

    static func launchProgram(_ plistPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        if let program = plist["Program"] as? String, !program.isEmpty { return program }
        if let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first, !first.isEmpty { return first }
        return nil
    }

    /// Unfinished installs: `~/Library/Application Support/*.install` older
    /// than a week, and Sparkle's "(… Sparkle …)" folders in Applications
    /// older than a day.
    func partialUpdates() -> [Leftover] {
        var result: [Leftover] = []
        let support = (home as NSString).appendingPathComponent("Library/Application Support")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: support)) ?? [] where name.hasSuffix(".install") {
            let path = (support as NSString).appendingPathComponent(name)
            guard Self.isDirectory(path), let modified = Self.modified(path),
                  now.timeIntervalSince(modified) >= Self.installAgeLimit else { continue }
            result.append(Leftover(path: path, kind: .partialUpdate, location: "Application Support", modified: modified))
        }
        for root in applicationFolders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where Self.isSparkleLeftoverName(name) {
                let path = (root as NSString).appendingPathComponent(name)
                guard Self.isDirectory(path), let modified = Self.modified(path),
                      now.timeIntervalSince(modified) >= Self.sparkleAgeLimit else { continue }
                result.append(Leftover(path: path, kind: .sparkle, location: (root as NSString).lastPathComponent, modified: modified))
            }
        }
        return result
    }

    /// "(A Document Being Saved By Sparkle)" in any language: a parenthesized
    /// name that mentions Sparkle.
    static func isSparkleLeftoverName(_ name: String) -> Bool {
        name.hasPrefix("(") && name.hasSuffix(")") && name.range(of: "sparkle", options: .caseInsensitive) != nil
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
