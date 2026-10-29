import Foundation

/// Locates the bundled Mole engine (the `mole` router, `bin/` and `lib/`)
/// and builds the environment every engine process runs with.
enum Engine {
    /// `MadMole.app/Contents/Resources/engine`, or `MADMOLE_ENGINE_DIR` when
    /// running an unbundled development build against a source checkout.
    static var rootURL: URL {
        if let override = ProcessInfo.processInfo.environment["MADMOLE_ENGINE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        return resources.appendingPathComponent("engine", isDirectory: true)
    }

    static var mole: String { rootURL.appendingPathComponent("mole").path }
    static var statusBinary: String { rootURL.appendingPathComponent("bin/status-go").path }
    static var analyzeBinary: String { rootURL.appendingPathComponent("bin/analyze-go").path }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: mole)
    }

    static var hasGoBinaries: Bool {
        FileManager.default.isExecutableFile(atPath: statusBinary)
            && FileManager.default.isExecutableFile(atPath: analyzeBinary)
    }

    /// The `VERSION="x.y.z"` line of the bundled router.
    static let version: String = {
        guard let text = try? String(contentsOfFile: mole, encoding: .utf8) else { return "?" }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(200) {
            if line.hasPrefix("VERSION=\"") {
                return line.dropFirst("VERSION=\"".count).replacingOccurrences(of: "\"", with: "")
            }
        }
        return "?"
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// A GUI app inherits launchd's minimal PATH. Give the engine the same
    /// tool locations a login shell has, including Homebrew on Apple Silicon.
    static let searchPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func environment(terminal: Bool) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[key] { env[key] = value }
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        env["PATH"] = searchPath
        env["LANG"] = "en_US.UTF-8"
        if terminal {
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
        } else {
            env["TERM"] = "dumb"
            env["NO_COLOR"] = "1"
        }
        return env
    }

    static func environmentList(terminal: Bool) -> [String] {
        environment(terminal: terminal).map { "\($0.key)=\($0.value)" }.sorted()
    }

    static var homeDirectory: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    static var cleanPreviewFile: URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/mole/clean-list.txt")
    }

    static var whitelistFile: URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/mole/whitelist")
    }

    static var logDirectory: URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Logs/mole", isDirectory: true)
    }
}
