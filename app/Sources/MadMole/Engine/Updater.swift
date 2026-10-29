import AppKit
import CryptoKit
import Foundation
import Observation

/// One MadMole build published as a GitHub release tagged `madmole-<build>`.
struct AppRelease: Equatable {
    let build: Int
    let version: String
    let notes: String
    let publishedAt: Date?
    let zipURL: URL
    let checksumURL: URL?
    let pageURL: URL?
}

enum UpdateError: LocalizedError {
    case server(Int)
    case missingAsset
    case checksumMismatch
    case invalidBundle(String)
    case notInstallable(String)

    var errorDescription: String? {
        switch self {
        case .server(403), .server(429):
            return "GitHub kısa süre içinde çok fazla sorgu aldı (HTTP 403). Birkaç dakika sonra tekrar deneyin."
        case let .server(status):
            return "GitHub yanıt vermedi (HTTP \(status)). İnternet bağlantınızı kontrol edip tekrar deneyin."
        case .missingAsset:
            return "Yeni sürümün indirme dosyası bulunamadı."
        case .checksumMismatch:
            return "İndirilen dosyanın doğrulaması tutmadı; güncelleme kurulmadı. Tekrar deneyin."
        case let .invalidBundle(reason):
            return "İndirilen uygulama doğrulanamadı: \(reason)"
        case let .notInstallable(reason):
            return reason
        }
    }
}

/// Network, verification and install steps. Nothing here touches UI state.
enum UpdateClient {
    static let tagPrefix = "madmole-"
    static let zipName = "MadMole.zip"

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static var repository: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "MadMoleUpdateRepo") as? String ?? ""
        return value.isEmpty || value.hasPrefix("__") ? "madduck666/MadMole" : value
    }

    static var releasesPage: URL? {
        URL(string: "https://github.com/\(repository)/releases")
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }

        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let publishedAt: String?
        let htmlUrl: String?
        let assets: [Asset]
    }

    /// The newest published MadMole build, or nil when there is none.
    static func fetchLatest() async throws -> AppRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30") else {
            throw UpdateError.server(0)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MadMole-Updater", forHTTPHeaderField: "User-Agent")
        // CI only: an anonymous runner IP hits GitHub's rate limit quickly.
        if let token = ProcessInfo.processInfo.environment["MADMOLE_GITHUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let releases = try decoder.decode([GitHubRelease].self, from: data)
        let iso = ISO8601DateFormatter()

        let candidates: [AppRelease] = releases.compactMap { release in
            guard !release.draft, release.tagName.hasPrefix(tagPrefix),
                  let build = Int(release.tagName.dropFirst(tagPrefix.count)),
                  let zip = release.assets.first(where: { $0.name == zipName }),
                  let zipURL = URL(string: zip.browserDownloadUrl) else { return nil }
            let checksum = release.assets.first { $0.name == zipName + ".sha256" }
            let title = release.name ?? ""
            let version = title.hasPrefix("MadMole ") ? String(title.dropFirst("MadMole ".count)) : "build \(build)"
            return AppRelease(
                build: build,
                version: version,
                notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                publishedAt: release.publishedAt.flatMap { iso.date(from: $0) },
                zipURL: zipURL,
                checksumURL: checksum.flatMap { URL(string: $0.browserDownloadUrl) },
                pageURL: release.htmlUrl.flatMap { URL(string: $0) }
            )
        }
        return candidates.max { $0.build < $1.build }
    }

    /// Where the running app can be replaced, or the reason it cannot.
    static func installTarget() -> Result<URL, UpdateError> {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let path = bundle.path
        guard path.hasSuffix(".app") else {
            return .failure(.notInstallable("Bu kopya bir uygulama paketi değil; güncelleme yalnızca kurulu MadMole.app için çalışır."))
        }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return .failure(.notInstallable("MadMole disk görüntüsünden ya da karantinadan çalışıyor. Önce Uygulamalar klasörüne taşıyın ve oradan açın."))
        }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return .failure(.notInstallable("\(parent) klasörüne yazma izniniz yok; güncelleme kurulamıyor."))
        }
        return .success(bundle)
    }

    static func makeWorkDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MadMoleUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("MadMole-Updater", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Compares the zip with the `<sha256>  MadMole.zip` file published next to it.
    static func verifyChecksum(of file: URL, checksumURL: URL, workDirectory: URL) async throws {
        let checksumFile = workDirectory.appendingPathComponent("checksum.txt")
        try await download(checksumURL, to: checksumFile)
        let expected = try String(contentsOf: checksumFile, encoding: .utf8)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first.map { $0.lowercased() } ?? ""
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected == actual else { throw UpdateError.checksumMismatch }
    }

    /// Unzips the release and checks that it is a signed MadMole of the
    /// expected build before anything replaces the running copy.
    static func unpackAndVerify(_ zip: URL, in workDirectory: URL, expectedBuild: Int) async throws -> URL {
        let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = try await CommandRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard unzip.succeeded else { throw UpdateError.invalidBundle("arşiv açılamadı") }

        let app = unpacked.appendingPathComponent("MadMole.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.invalidBundle("Info.plist yok")
        }
        let bundleID = info["CFBundleIdentifier"] as? String
        guard bundleID == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("paket kimliği farklı (\(bundleID ?? "?"))")
        }
        guard Int(info["CFBundleVersion"] as? String ?? "") == expectedBuild else {
            throw UpdateError.invalidBundle("sürüm numarası beklenenle eşleşmiyor")
        }
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/Resources/engine/mole").path) else {
            throw UpdateError.invalidBundle("Mole motoru eksik")
        }
        let signature = try await CommandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.succeeded else { throw UpdateError.invalidBundle("kod imzası geçersiz") }
        return app
    }

    /// Starts a small helper that waits for this process to quit, swaps the
    /// new bundle in (keeping the old one until the copy succeeds) and opens
    /// the updated app.
    static func launchSwapper(newApp: URL, target: URL, workDirectory: URL) throws {
        let script = workDirectory.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        pid="$1"; new_app="$2"; target="$3"
        n=0
        while kill -0 "$pid" 2>/dev/null; do
            n=$((n + 1)); [ "$n" -gt 300 ] && exit 1
            sleep 0.2
        done
        backup="${target%.app}.previous.app"
        [ -d "$backup" ] && rm -rf "$backup"
        if mv "$target" "$backup"; then
            if /usr/bin/ditto "$new_app" "$target"; then
                /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
                rm -rf "$backup"
                /usr/bin/open "$target"
                exit 0
            fi
            rm -rf "$target"
            mv "$backup" "$target"
        fi
        /usr/bin/open "$target"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

@MainActor
@Observable
final class UpdateStore {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    static let autoCheckKey = "autoCheckUpdates"

    private(set) var phase: Phase = .idle
    private(set) var latest: AppRelease?
    private(set) var lastChecked: Date?
    var showSheet = false

    var currentVersion: String { Engine.appVersion }
    var currentBuild: Int { UpdateClient.currentBuild }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var updateAvailable: Bool {
        if let latest { return latest.build > currentBuild }
        return false
    }

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey) }
    }

    /// A quiet check at launch: an available update shows a banner, while
    /// errors stay silent.
    func checkAtLaunch() {
        guard autoCheck, ProcessInfo.processInfo.environment["MADMOLE_START_PAGE"] == nil else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        if userInitiated { showSheet = true }
        guard !isBusy else { return }
        phase = .checking
        Task {
            do {
                let release = try await UpdateClient.fetchLatest()
                self.latest = release
                self.lastChecked = Date()
                self.phase = self.updateAvailable ? .available : .upToDate
            } catch {
                self.phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    /// `MADMOLE_UPDATE_SELFTEST=1`: check and install without any UI, so CI
    /// can prove an older copy updates itself from the real releases.
    func runSelfTest() {
        phase = .checking
        Task {
            self.latest = try? await UpdateClient.fetchLatest()
            self.phase = self.updateAvailable ? .available : .upToDate
            if self.updateAvailable { self.install() }
        }
    }

    /// Downloads, verifies and installs the latest release, then quits so
    /// the helper can swap the bundle and relaunch.
    func install() {
        guard let release = latest, updateAvailable, !isBusy else { return }
        let target: URL
        switch UpdateClient.installTarget() {
        case let .success(url): target = url
        case let .failure(error):
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .downloading
        Task {
            do {
                let work = try UpdateClient.makeWorkDirectory()
                let zip = work.appendingPathComponent(UpdateClient.zipName)
                try await UpdateClient.download(release.zipURL, to: zip)
                guard let checksumURL = release.checksumURL else { throw UpdateError.missingAsset }
                try await UpdateClient.verifyChecksum(of: zip, checksumURL: checksumURL, workDirectory: work)
                self.phase = .installing
                let app = try await UpdateClient.unpackAndVerify(zip, in: work, expectedBuild: release.build)
                try UpdateClient.launchSwapper(newApp: app, target: target, workDirectory: work)
                NSApp.terminate(nil)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}
