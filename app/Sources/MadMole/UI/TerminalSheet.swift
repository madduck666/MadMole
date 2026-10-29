import AppKit
import Observation
import SwiftTerm
import SwiftUI

// SwiftTerm defines its own `Color`; this file names SwiftUI's explicitly.

@MainActor
@Observable
final class TerminalController {
    enum State: Equatable {
        case running
        case finished(Int32?)
    }

    var state: State = .running
    @ObservationIgnored weak var view: LocalProcessTerminalView?

    var isRunning: Bool { state == .running }

    var exitCode: Int32? {
        if case let .finished(code) = state { return code }
        return nil
    }

    /// Sends Ctrl-C, which the engine treats as a clean cancellation.
    func interrupt() {
        view?.send(txt: "\u{03}")
    }

    func terminate() {
        view?.terminate()
    }

    func focus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }
}

struct TerminalHostView: NSViewRepresentable {
    let job: TerminalJob
    let controller: TerminalController

    static let background = NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.106, alpha: 1)

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 860, height: 480))
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = Self.background
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        view.caretColor = NSColor.systemTeal
        view.processDelegate = context.coordinator
        controller.view = view
        view.startProcess(
            executable: Engine.mole,
            args: job.arguments,
            environment: Engine.environmentList(terminal: true),
            execName: nil,
            currentDirectory: Engine.homeDirectory
        )
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let controller: TerminalController

        init(controller: TerminalController) {
            self.controller = controller
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let controller = self.controller
            Task { @MainActor in
                controller.state = .finished(exitCode)
            }
        }
    }
}

struct TerminalSheet: View {
    let job: TerminalJob
    @Environment(\.dismiss) private var dismiss
    @State private var controller = TerminalController()
    @State private var confirmForceClose = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalHostView(job: job, controller: controller)
                .padding(10)
                .background(SwiftUI.Color(nsColor: TerminalHostView.background))
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 540, idealHeight: 640)
        .interactiveDismissDisabled(controller.isRunning)
        .onDisappear {
            if controller.isRunning { controller.terminate() }
            job.onFinish?(controller.exitCode)
        }
        .confirmationDialog("İşlem hâlâ çalışıyor", isPresented: $confirmForceClose) {
            Button("Durdur ve kapat", role: .destructive) {
                controller.terminate()
                dismiss()
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Önce \"Durdur\" ile işlemin kendini güvenle bitirmesini beklemeniz önerilir.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "terminal.fill", tint: job.tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(job.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(job.commandLine)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 320, alignment: .trailing)
            statusBadge
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch controller.state {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Çalışıyor")
            }
            .font(.callout.weight(.medium))
        case let .finished(code):
            if code == 0 {
                Label("Tamamlandı", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.green)
                    .font(.callout.weight(.semibold))
            } else {
                Label("Bitti (kod \(code.map(String.init) ?? "?"))", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.orange)
                    .font(.callout.weight(.semibold))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            Text("Terminal klavyeyi dinler: onaylar, seçimler ve yönetici şifresi (veya Touch ID) burada istenir.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if controller.isRunning {
                Button {
                    controller.interrupt()
                    controller.focus()
                } label: {
                    Label("Durdur", systemImage: "stop.circle")
                }
                .help("Ctrl-C gönderir; motor işlemi güvenle sonlandırır")
                Button("Kapat") { confirmForceClose = true }
            } else {
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(GradientButtonStyle(tint: job.tint))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
