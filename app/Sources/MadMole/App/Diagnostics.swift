import AppKit
import Foundation

/// A plain-text report the user can paste into a bug report: versions,
/// where the app runs from, the permission probe and recent engine output.
/// It holds no file contents, only paths Mole already logs.
enum Diagnostics {
    @MainActor
    static func report(model: AppModel) -> String {
        let info = ProcessInfo.processInfo
        var lines: [String] = []
        lines.append("MadMole tanılama raporu, \(Date().formatted(date: .numeric, time: .standard))")
        lines.append("Uygulama: \(Engine.appVersion) (build \(UpdateClient.currentBuild))")
        lines.append("Motor: \(Engine.version), Go araçları: \(Engine.hasGoBinaries ? "var" : "eksik")")
        lines.append("macOS: \(info.operatingSystemVersionString)")
        lines.append("Konum: \(Bundle.main.bundleURL.path)")
        lines.append("Açık sayfa: \(model.page.rawValue)")
        lines.append("Güncelleme durumu: \(String(describing: model.updates.phase))")
        lines.append("")
        lines.append("Tam Disk Erişimi: \(String(describing: Permissions.fullDiskAccess))")
        for probe in Permissions.probe() {
            let state = probe.exists ? (probe.readable ? "okunabilir" : "okunamıyor") : "yok"
            lines.append("  \(TextUtils.abbreviatePath(probe.path)): \(state)")
        }
        lines.append("")
        lines.append("Konsol (son 150 satır):")
        for line in model.console.lines.suffix(150) {
            lines.append("[\(line.source)] \(line.text)")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func copyReport(model: AppModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(model: model), forType: .string)
    }
}
