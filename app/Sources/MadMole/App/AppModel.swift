import AppKit
import Foundation
import Observation
import SwiftUI

/// Every page of the app, in sidebar order.
enum Page: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case clean
    case uninstall
    case analyze
    case optimize
    case purge
    case installer
    case slim
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Genel Bakış"
        case .clean: return "Akıllı Temizlik"
        case .uninstall: return "Uygulama Kaldırıcı"
        case .analyze: return "Disk Analizi"
        case .optimize: return "Optimizasyon"
        case .purge: return "Proje Artıkları"
        case .installer: return "Kurulum Dosyaları"
        case .slim: return "Uygulama İnceltme"
        case .history: return "Geçmiş"
        case .settings: return "Ayarlar"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: return "Mac'inizin anlık sağlık durumu"
        case .clean: return "Önbellek, log ve geçici dosyaları güvenle temizleyin"
        case .uninstall: return "Uygulamaları artıklarıyla birlikte kaldırın"
        case .analyze: return "Diskinizde yer kaplayanları keşfedin"
        case .optimize: return "Sistem önbelleklerini ve servislerini tazeleyin"
        case .purge: return "node_modules, target, build gibi derleme artıklarını silin"
        case .installer: return ".dmg, .pkg, .iso, .xip ve .zip kurulum dosyalarını bulun"
        case .slim: return "Evrensel uygulamalardan Intel kodunu çıkarın"
        case .history: return "Yapılan her işlemin kaydı"
        case .settings: return "İzinler, korunan yollar ve Touch ID"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .clean: return "sparkles"
        case .uninstall: return "trash.square.fill"
        case .analyze: return "chart.pie.fill"
        case .optimize: return "bolt.heart.fill"
        case .purge: return "hammer.fill"
        case .installer: return "shippingbox.fill"
        case .slim: return "scissors"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: return Theme.indigo
        case .clean: return Theme.teal
        case .uninstall: return Theme.pink
        case .analyze: return Theme.orange
        case .optimize: return Theme.green
        case .purge: return Theme.purple
        case .installer: return Theme.blue
        case .slim: return Theme.yellow
        case .history: return Theme.gray
        case .settings: return Theme.gray
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.85), tint],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let groups: [(String, [Page])] = [
        ("Genel", [.dashboard]),
        ("Temizlik", [.clean, .purge, .installer]),
        ("Uygulamalar", [.uninstall, .slim]),
        ("Disk ve Sistem", [.analyze, .optimize]),
        ("Kayıtlar", [.history]),
    ]
}

/// A CLI run shown in the embedded terminal sheet. The engine keeps its own
/// confirmation and administrator prompts there, exactly as in Terminal.
struct TerminalJob: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let arguments: [String]
    var tint: Color = Theme.indigo
    var onFinish: ((Int32?) -> Void)?

    var commandLine: String {
        (["mo"] + arguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Sistem"
        case .light: return "Açık"
        case .dark: return "Koyu"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct ConsoleLine: Identifiable {
    let id = UUID()
    let date: Date
    let source: String
    let text: String
}

/// The collapsible output panel at the bottom of the window. Read-only engine
/// runs (previews, scans) stream their output here so nothing happens out of
/// sight.
@MainActor
@Observable
final class ConsoleLog {
    private(set) var lines: [ConsoleLine] = []
    var isVisible = false
    private let limit = 2000

    func append(_ text: String, source: String) {
        let clean = TextUtils.stripANSI(text)
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty, !TextUtils.isDecoration(clean) else { return }
        lines.append(ConsoleLine(date: Date(), source: source, text: clean))
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    func clear() {
        lines.removeAll()
    }

    /// A line handler that hops back to the main actor.
    nonisolated func sink(source: String) -> @Sendable (String) -> Void {
        { line in
            Task { @MainActor in
                self.append(line, source: source)
            }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var page: Page = .dashboard
    var terminalJob: TerminalJob?
    let console = ConsoleLog()

    let dashboard = DashboardStore()
    let clean = CleanStore()
    let uninstall = UninstallStore()
    let analyze = AnalyzeStore()
    let history = HistoryStore()
    let tools: [Page: ToolStore]

    init() {
        var tools: [Page: ToolStore] = [:]
        for page in [Page.optimize, .purge, .installer, .slim] {
            if let spec = ToolSpec.spec(for: page) {
                tools[page] = ToolStore(spec: spec)
            }
        }
        self.tools = tools
        clean.console = console
        uninstall.console = console
        analyze.console = console
        for store in tools.values {
            store.console = console
        }
        applyLaunchOptions(ProcessInfo.processInfo.environment)
    }

    /// `MADMOLE_START_PAGE=<page>` opens a page at launch and
    /// `MADMOLE_AUTORUN=1` starts its read-only scan; CI uses both to take
    /// screenshots of every page.
    private func applyLaunchOptions(_ environment: [String: String]) {
        if let appearance = environment["MADMOLE_APPEARANCE"], AppearanceMode(rawValue: appearance) != nil {
            UserDefaults.standard.set(appearance, forKey: AppearanceMode.storageKey)
        }
        guard let raw = environment["MADMOLE_START_PAGE"], let start = Page(rawValue: raw) else { return }
        page = start
        if environment["MADMOLE_CONSOLE"] == "1" { console.isVisible = true }
        guard environment["MADMOLE_AUTORUN"] == "1" else { return }
        switch start {
        case .clean: clean.scan()
        case .analyze: analyze.open(AnalyzeStore.Location(path: Engine.homeDirectory + "/Library"))
        case .optimize, .purge, .installer, .slim: tools[start]?.preview()
        default: break
        }
    }

    func runInTerminal(
        title: String,
        subtitle: String,
        arguments: [String],
        tint: Color = Theme.indigo,
        onFinish: ((Int32?) -> Void)? = nil
    ) {
        terminalJob = TerminalJob(title: title, subtitle: subtitle, arguments: arguments, tint: tint, onFinish: onFinish)
    }
}
