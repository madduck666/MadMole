import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // An unbundled `swift run` starts as a background process; make it a
        // regular app with a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MadMoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MadMole", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Güncellemeleri Denetle…") { model.updates.check(userInitiated: true) }
            }
            CommandGroup(replacing: .help) {
                Button("Tanılama Bilgisini Kopyala") { Diagnostics.copyReport(model: model) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Ayarlar…") { model.page = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Git") {
                let pages = Page.allCases.filter { $0 != .settings }
                ForEach(pages.indices, id: \.self) { index in
                    let page = pages[index]
                    if index < 9 {
                        Button(page.title) { model.page = page }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button(page.title) { model.page = page }
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Button(model.console.isVisible ? "Konsolu Gizle" : "Konsolu Göster") {
                    model.console.isVisible.toggle()
                }
                .keyboardShortcut("j", modifiers: [.command])
            }
        }
    }
}
