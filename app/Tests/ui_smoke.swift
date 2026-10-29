// UI smoke test for MadMole.app, run in CI on a real macOS session.
//
// Launches the app, clicks every sidebar row with real mouse events and checks
// that the page header changed to that row's title. A screenshot of each page
// goes to the output folder.
//
// Usage: ui_smoke <MadMole.app> [screenshot-dir]
// Exit:  0 all pages opened, 1 a page failed, 3 no Accessibility permission.

import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let pages = [
    "Akıllı Temizlik", "Proje Artıkları", "Kurulum Dosyaları",
    "Uygulama Kaldırıcı", "Uygulama İnceltme", "Disk Analizi",
    "Optimizasyon", "Geçmiş", "Genel Bakış",
]

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String {
    attribute(element, kAXRoleAttribute) as? String ?? ""
}

func label(_ element: AXUIElement) -> String {
    for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let text = attribute(element, key) as? String, !text.isEmpty { return text }
    }
    return ""
}

func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Void) {
    guard depth < 60 else { return }
    visit(element, depth)
    for child in children(element) {
        walk(child, depth: depth + 1, visit)
    }
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute),
          let size = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    // swiftlint:disable force_cast
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    // swiftlint:enable force_cast
    return CGRect(origin: point, size: extent)
}

func click(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(90000)
    }
}

func textCount(in root: AXUIElement, equalTo title: String) -> Int {
    var count = 0
    walk(root) { element, _ in
        if role(element) == "AXStaticText", label(element) == title { count += 1 }
    }
    return count
}

func sidebarRow(in root: AXUIElement, titled title: String) -> AXUIElement? {
    var found: AXUIElement?
    walk(root) { element, _ in
        guard found == nil, role(element) == "AXRow" else { return }
        walk(element) { inner, _ in
            if found == nil, label(inner) == title { found = element }
        }
    }
    return found
}

func dumpTree(_ root: AXUIElement, limit: Int = 250) {
    var printed = 0
    walk(root) { element, depth in
        guard printed < limit else { return }
        printed += 1
        let text = label(element)
        print(String(repeating: "  ", count: min(depth, 20)) + role(element) + (text.isEmpty ? "" : " \"\(text)\""))
    }
}

func screenshot(_ path: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", path]
    try? process.run()
    process.waitUntilExit()
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: ui_smoke <MadMole.app> [screenshot-dir]")
    exit(2)
}
let appPath = arguments[1]
let shotDirectory = arguments.count > 2 ? arguments[2] : nil

guard AXIsProcessTrusted() else {
    print("NOT_TRUSTED: this process has no Accessibility permission")
    exit(3)
}

let app = Process()
app.executableURL = URL(fileURLWithPath: appPath + "/Contents/MacOS/MadMole")
var environment = ProcessInfo.processInfo.environment
// Opens on the dashboard and skips the launch update check.
environment["MADMOLE_START_PAGE"] = "dashboard"
app.environment = environment
try app.run()

var window: AXUIElement?
let axApp = AXUIElementCreateApplication(app.processIdentifier)
for _ in 0..<40 {
    NSRunningApplication(processIdentifier: app.processIdentifier)?.activate(options: [])
    if let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement], let first = windows.first {
        window = first
        break
    }
    usleep(500_000)
}
guard let window else {
    print("FAIL: MadMole opened no window")
    app.terminate()
    exit(1)
}
sleep(3)

var failures: [String] = []
for (index, title) in pages.enumerated() {
    NSRunningApplication(processIdentifier: app.processIdentifier)?.activate(options: [])
    guard let row = sidebarRow(in: window, titled: title), let rect = frame(row) else {
        failures.append("\(title): no sidebar row")
        print("FAIL \(title): no sidebar row")
        continue
    }
    click(CGPoint(x: rect.midX, y: rect.midY))
    usleep(1_800_000)
    let count = textCount(in: window, equalTo: title)
    let selected = attribute(row, kAXSelectedAttribute) as? Bool ?? false
    if count >= 2 {
        print("PASS \(title) (selected=\(selected))")
    } else {
        failures.append("\(title): page did not open")
        print("FAIL \(title): page did not open (title texts=\(count), selected=\(selected))")
    }
    if let shotDirectory {
        screenshot("\(shotDirectory)/ui-\(index + 1).png")
    }
}

if !failures.isEmpty {
    print("\nAccessibility tree for debugging:")
    dumpTree(window)
    print("\n\(failures.count) page(s) failed:")
    failures.forEach { print("  - \($0)") }
    app.terminate()
    exit(1)
}
print("\nAll \(pages.count) sidebar pages opened by click.")
app.terminate()
exit(0)
