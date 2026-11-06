// Logic tests for MadMole's external-disk move, app-data sizing and leftover
// finder. Built with plain swiftc against the engine-facing sources, so they
// run with Command Line Tools alone (no Xcode, no XCTest):
//
//   app/Tests/run_logic_tests.sh
//
// Every case works in a throwaway folder. Trash moves go to the engine's
// test-only Trash folder (MOLE_TEST_TRASH_DIR with MOLE_TEST_NO_AUTH=1) under
// a fixture HOME, so no real file is touched.
// Exit: 0 all passed, 1 a case failed.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var current = ""

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("  FAIL [\(current)] line \(line): \(message)")
    }
}

@MainActor
func test(_ name: String, _ body: () async throws -> Void) async {
    current = name
    let before = failures
    do {
        try await body()
    } catch {
        failures += 1
        print("  FAIL [\(name)] threw: \(error)")
    }
    print((failures == before ? "ok   " : "FAIL ") + name)
}

/// A throwaway folder for one case, removed afterwards.
final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("madmole-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func path(_ relative: String) -> String { url(relative).path }

    @discardableResult
    func folder(_ relative: String, age days: Double? = nil) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let days { try setAge(url, days: days) }
        return url
    }

    @discardableResult
    func file(_ relative: String, _ contents: String = "x", age days: Double? = nil) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if let days { try setAge(url, days: days) }
        return url
    }

    func setAge(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)],
                                              ofItemAtPath: url.path)
    }

    /// The helper against this checkout's engine, with a fixture HOME whose
    /// protected-path list is `whitelist`.
    func helper(whitelist: [String]) throws -> EngineHelper {
        try folder("home")
        try folder("trash")
        try file("home/.config/mole/whitelist", whitelist.joined(separator: "\n") + "\n")
        var environment = Engine.environment(terminal: false)
        environment["HOME"] = path("home")
        environment["MOLE_TEST_NO_AUTH"] = "1"
        environment["MOLE_TEST_TRASH_DIR"] = path("trash")
        return EngineHelper(script: repository.appendingPathComponent("app/Resources/madmole-helper.sh").path,
                            engineRoot: repository.path, environment: environment)
    }
}

guard CommandLine.arguments.count == 2 else {
    print("usage: logic_tests <repository-root>")
    exit(2)
}
let repository = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL

// MARK: - Move to an external disk

await test("an identical copy verifies") {
    let fx = try Fixture()
    try fx.file("src/Photos/a.jpg", String(repeating: "a", count: 10_000))
    try fx.file("src/Photos/b.jpg", "bbb")
    try fx.file("src/notes.txt", "hello")
    try fx.folder("src/Empty")
    try FileManager.default.createSymbolicLink(atPath: fx.path("src/link"), withDestinationPath: "notes.txt")
    try fx.folder("disk")

    let target = SafeMove.destination(for: fx.url("src"), in: fx.url("disk"))
    try await SafeMove.copy(from: fx.url("src"), to: target)
    let report = try SafeMove.verify(source: fx.url("src"), copy: target)

    expect(report.isIdentical, "copy should match: \(report)")
    expect(report.files == 3, "files \(report.files)")
    expect(report.folders == 3, "folders \(report.folders)")
    expect(report.links == 1, "links \(report.links)")
    expect(report.bytes == 10_008, "bytes \(report.bytes)")
}

await test("a single file verifies") {
    let fx = try Fixture()
    try fx.file("recording.mov", String(repeating: "z", count: 5000))
    try fx.folder("disk")
    let target = SafeMove.destination(for: fx.url("recording.mov"), in: fx.url("disk"))
    try await SafeMove.copy(from: fx.url("recording.mov"), to: target)
    let report = try SafeMove.verify(source: fx.url("recording.mov"), copy: target)
    expect(report.isIdentical && report.files == 1, "\(report)")
}

await test("missing and different files are counted") {
    let fx = try Fixture()
    try fx.file("src/same.txt", "same")
    try fx.file("src/changed.txt", "AAAA")
    try fx.file("src/gone.txt", "gone")
    try fx.file("copy/same.txt", "same")
    try fx.file("copy/changed.txt", "AAAB") // same size, one byte differs

    let report = try SafeMove.verify(source: fx.url("src"), copy: fx.url("copy"))
    expect(!report.isIdentical, "must not verify")
    expect(report.missing == 1, "missing \(report.missing)")
    expect(report.different == 1, "different \(report.different)")
    expect(report.unreadable == 0, "unreadable \(report.unreadable)")
    expect(report.examples.contains("src/gone.txt") && report.examples.contains("src/changed.txt"), "\(report.examples)")
}

await test("a different symlink target is a difference") {
    let fx = try Fixture()
    try fx.folder("src")
    try fx.folder("copy")
    try FileManager.default.createSymbolicLink(atPath: fx.path("src/l"), withDestinationPath: "one")
    try FileManager.default.createSymbolicLink(atPath: fx.path("copy/l"), withDestinationPath: "two")
    let report = try SafeMove.verify(source: fx.url("src"), copy: fx.url("copy"))
    expect(report.different == 1 && !report.isIdentical, "\(report)")
}

await test("an unreadable source file blocks verification") {
    let fx = try Fixture()
    let secret = try fx.file("src/secret.txt", "s")
    try fx.file("copy/secret.txt", "s")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
    let report = try SafeMove.verify(source: fx.url("src"), copy: fx.url("copy"))
    expect(report.unreadable == 1 && !report.isIdentical, "\(report)")
}

await test("an existing name at the destination stops the move") {
    let fx = try Fixture()
    try fx.file("FOTO/a.jpg")
    try fx.file("disk/FOTO/other.jpg")
    let problems = SafeMove.preflight(source: fx.url("FOTO"), folder: fx.url("disk"), sourceBytes: 1, availableBytes: nil)
    expect(problems.contains(.destinationExists(fx.path("disk/FOTO"))), "\(problems)")
}

await test("copy never overwrites an existing target") {
    let fx = try Fixture()
    try fx.file("src/a.txt", "new")
    try fx.file("disk/src/a.txt", "old")
    var threw = false
    do { try await SafeMove.copy(from: fx.url("src"), to: fx.url("disk/src")) } catch { threw = true }
    expect(threw, "copy must refuse")
    expect((try? String(contentsOf: fx.url("disk/src/a.txt"), encoding: .utf8)) == "old", "target changed")
}

await test("preflight checks space, nesting, missing folders and the same disk") {
    let fx = try Fixture()
    try fx.file("src/a.txt")
    try fx.folder("disk")

    let small = SafeMove.preflight(source: fx.url("src"), folder: fx.url("disk"), sourceBytes: 10_000_000_000, availableBytes: 1_000_000_000)
    expect(small.contains { if case .notEnoughSpace = $0 { return true } else { return false } }, "\(small)")
    expect(small.contains(.sameVolume), "fixture folders share one disk: \(small)")

    let nested = SafeMove.preflight(source: fx.url("src"), folder: fx.url("src"), sourceBytes: 1, availableBytes: nil)
    expect(nested.contains(.nested), "\(nested)")

    let missing = SafeMove.preflight(source: fx.url("src"), folder: fx.url("unplugged"), sourceBytes: 1, availableBytes: nil)
    expect(missing == [.destinationFolderMissing], "\(missing)")

    let gone = SafeMove.preflight(source: fx.url("nothing"), folder: fx.url("disk"), sourceBytes: 1, availableBytes: nil)
    expect(gone == [.sourceMissing], "\(gone)")
}

// MARK: - Engine helper (protected paths, Trash funnel, uninstall inventory)

await test("protected paths and folders holding them are refused") {
    let fx = try Fixture()
    let home = fx.path("home")
    let helper = try fx.helper(whitelist: ["\(home)/Work/keep", "\(home)/Projects/*/secret"])
    try fx.file("home/Work/keep/a.txt")
    try fx.file("home/Work/other/b.txt")
    try fx.file("home/Projects/alpha/secret/c.txt")
    try fx.file("home/Movies/clip.mov")

    let results = try await helper.check(["\(home)/Work/keep", "\(home)/Work", "\(home)/Projects/alpha", "\(home)/Movies", "/System"])
    let verdict = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.verdict) })
    expect(verdict["\(home)/Work/keep"] == .refused(reason: "whitelist"), "\(String(describing: verdict["\(home)/Work/keep"]))")
    expect(verdict["\(home)/Work"] != nil && verdict["\(home)/Work"] != .allowed, "parent of a protected path")
    expect(verdict["\(home)/Projects/alpha"] == .refused(reason: "contains-whitelisted"), "\(String(describing: verdict["\(home)/Projects/alpha"]))")
    expect(verdict["\(home)/Movies"] == .allowed, "\(String(describing: verdict["\(home)/Movies"]))")
    expect(verdict["/System"] == .refused(reason: "protected"), "\(String(describing: verdict["/System"]))")
}

await test("trash moves only allowed paths and logs every one") {
    let fx = try Fixture()
    let home = fx.path("home")
    let helper = try fx.helper(whitelist: ["\(home)/Data/keep"])
    try fx.file("home/Data/go/file.txt", "bye")
    try fx.file("home/Data/keep/file.txt", "stay")

    let results = try await helper.trash(["\(home)/Data/go", "\(home)/Data/keep"], command: "madmole-test")
    expect(results.first { $0.path.hasSuffix("/go") }?.verdict == .allowed, "\(results)")
    expect(results.first { $0.path.hasSuffix("/keep") }?.verdict == .refused(reason: "whitelist"), "\(results)")
    expect(!FileManager.default.fileExists(atPath: "\(home)/Data/go"), "moved folder still in place")
    expect(FileManager.default.fileExists(atPath: "\(home)/Data/keep/file.txt"), "protected folder touched")
    let trashed = (try? FileManager.default.contentsOfDirectory(atPath: fx.path("trash"))) ?? []
    expect(trashed.contains { $0.hasPrefix("go") }, "Trash holds \(trashed)")

    let log = (try? String(contentsOfFile: "\(home)/Library/Logs/mole/operations.log", encoding: .utf8)) ?? ""
    expect(log.contains("madmole-test run="), "session marker missing")
    expect(log.contains("TRASHED \(home)/Data/go"), "TRASHED row missing")
    expect(log.contains("SKIPPED \(home)/Data/keep (whitelist)"), "SKIPPED row missing")
}

await test("app files come from the uninstall inventory, one answer per app") {
    let fx = try Fixture()
    let home = fx.path("home")
    let helper = try fx.helper(whitelist: [])
    try fx.file("home/Library/Containers/com.example.editor/Data/x", String(repeating: "d", count: 100))
    try fx.file("home/Library/Application Support/com.example.editor/y")

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var byApp: [Int: [String]] = [:]
    }
    let box = Box()
    try await helper.appFiles([
        .init(bundleId: "com.example.editor", name: "Example Editor", path: "/Applications/Example Editor.app"),
        .init(bundleId: "com.example.none", name: "Nothing Here", path: "/Applications/Nothing Here.app"),
    ]) { index, files in
        box.lock.lock()
        box.byApp[index] = files
        box.lock.unlock()
    }
    expect(box.byApp.count == 2, "\(box.byApp)")
    expect(box.byApp[0]?.contains("\(home)/Library/Containers/com.example.editor") == true, "\(box.byApp[0] ?? [])")
    expect(box.byApp[0]?.contains("\(home)/Library/Application Support/com.example.editor") == true, "\(box.byApp[0] ?? [])")
    expect(box.byApp[1] == [], "\(box.byApp[1] ?? ["nil"])")
}

await test("helper output parsing") {
    let lines = "ok\t/a b\nrefused\twhitelist\t/c\nfailed\t7\t/d\nnoise\n"
    expect(EngineHelper.parsePathResults(lines) == [
        .init(path: "/a b", verdict: .allowed),
        .init(path: "/c", verdict: .refused(reason: "whitelist")),
        .init(path: "/d", verdict: .failed(status: "7")),
    ], "path results")
    let report = EngineHelper.parseOrphanReport("installed\tcom.x.app\norphan\t/p/one\nname\t/p/Two\n")
    expect(report.installedBundles == ["com.x.app"], "\(report.installedBundles)")
    expect(report.verdicts == ["/p/one": "orphan", "/p/Two": "name"], "\(report.verdicts)")
}

await test("nested app-data paths count once") {
    expect(DiskUsage.outermost(["/a/b/c", "/a/b", "/a/bc", "/a/b"]) == ["/a/b", "/a/bc"], "\(DiskUsage.outermost(["/a/b/c", "/a/b", "/a/bc"]))")
}

// MARK: - Leftover finder

func scanner(_ fx: Fixture) -> LeftoverScanner {
    LeftoverScanner(home: fx.path("home"), applicationFolders: [fx.path("Applications")])
}

await test("app data follows the engine verdict and skips extensions of installed apps") {
    let fx = try Fixture()
    try fx.folder("Applications/Editor.app")
    let gone = try fx.folder("home/Library/Containers/com.removed.app", age: 90)
    let ext = try fx.folder("home/Library/Containers/com.vendor.editor.ShareExtension", age: 90)
    let kept = try fx.folder("home/Library/Containers/com.vendor.editor", age: 90)
    let s = scanner(fx)
    let candidates = s.dataCandidates()
    expect(candidates.contains { $0.path == gone.path && $0.id == "com.removed.app" }, "candidate list")

    var report = EngineHelper.OrphanReport()
    report.installedBundles = ["com.vendor.editor"]
    report.verdicts = [gone.path: "orphan", ext.path: "orphan", kept.path: "keep"]
    let found = s.appData(candidates: candidates, report: report).map(\.path)
    expect(found == [gone.path], "\(found)")
}

await test("plain names need a program, an old date and no installed match") {
    let fx = try Fixture()
    try fx.folder("Applications/Google Chrome.app")
    let steam = try fx.folder("home/Library/Application Support/Steam")
    try fx.folder("home/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")
    try fx.setAge(steam, days: 60)
    let google = try fx.folder("home/Library/Application Support/Google")
    try fx.folder("home/Library/Application Support/Google/Updater.app")
    try fx.setAge(google, days: 60)
    let plain = try fx.folder("home/Library/Application Support/Notes Export", age: 60)
    let fresh = try fx.folder("home/Library/Application Support/FreshTool")
    try fx.folder("home/Library/Application Support/FreshTool/Tool.app")
    let s = scanner(fx)

    var report = EngineHelper.OrphanReport()
    report.installedBundles = ["com.google.chrome"]
    for url in [steam, google, plain, fresh] { report.verdicts[url.path] = "name" }
    let found = s.appData(candidates: s.dataCandidates(), report: report)
    expect(found.map(\.path) == [steam.path], "\(found.map(\.path))")
    expect(found.first?.kind == .nameOnly, "kind")
}

await test("launch items need a missing or orphaned program") {
    let fx = try Fixture()
    let orphanFolder = fx.path("home/Library/Application Support/Steam")
    try fx.file("home/Library/Application Support/Steam/steamclean")
    let live = try fx.file("Applications/Live.app/Contents/MacOS/live")
    try fx.folder("home/Library/LaunchAgents")
    func agent(_ name: String, _ plist: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: fx.url("home/Library/LaunchAgents/\(name)"))
    }
    try agent("com.valvesoftware.steamclean.plist", ["ProgramArguments": ["\(orphanFolder)/steamclean"]])
    try agent("com.gone.agent.plist", ["Program": "/nonexistent/tool"])
    try agent("com.live.agent.plist", ["Program": live.path])
    try agent("com.noprogram.plist", ["Label": "x"])

    let names = scanner(fx).launchItems(orphanFolders: [orphanFolder]).map(\.name).sorted()
    expect(names == ["com.gone.agent.plist", "com.valvesoftware.steamclean.plist"], "\(names)")
}

await test("unfinished updates need age") {
    let fx = try Fixture()
    let old = try fx.folder("home/Library/Application Support/com.docker.install", age: 20)
    try fx.folder("home/Library/Application Support/com.fresh.install")
    let sparkle = try fx.folder("Applications/(A Document Being Saved By Sparkle)", age: 3)
    try fx.folder("Applications/(Sparkle Tarafından Kaydedilen Bir Belge)")
    let found = scanner(fx).partialUpdates()
    expect(Set(found.map(\.path)) == [old.path, sparkle.path], "\(found.map(\.path))")
    expect(found.first { $0.path == sparkle.path }?.kind == .sparkle, "kind")
}

await test("Sparkle leftover names in any language") {
    expect(LeftoverScanner.isSparkleLeftoverName("(A Document Being Saved By Sparkle)"), "English")
    expect(LeftoverScanner.isSparkleLeftoverName("(Sparkle Tarafından Kaydedilen Bir Belge)"), "Turkish")
    expect(!LeftoverScanner.isSparkleLeftoverName("Sparkle.app"), "an app")
    expect(!LeftoverScanner.isSparkleLeftoverName("(Untitled)"), "no Sparkle")
}

print(failures == 0 ? "\nAll logic tests passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
