import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 300)
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    Theme.backdrop(model.page.tint)
                    if Engine.isAvailable {
                        detail
                            .id(model.page)
                            .transition(.opacity)
                    } else {
                        EngineMissingView()
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: model.page)
                ConsolePanel(console: model.console)
            }
            .background(Theme.windowBackground)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { model.console.isVisible.toggle() }
                    } label: {
                        Label("Konsol", systemImage: model.console.isVisible ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomthird.inset.filled")
                    }
                    .help("Motor çıktısını göster/gizle (⌘J)")
                }
            }
        }
        .sheet(item: $model.terminalJob) { job in
            TerminalSheet(job: job)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .dashboard:
            DashboardView(store: model.dashboard)
        case .clean:
            CleanView(store: model.clean)
        case .uninstall:
            UninstallView(store: model.uninstall)
        case .analyze:
            AnalyzeView(store: model.analyze)
        case .optimize, .purge, .installer, .slim:
            if let store = model.tools[model.page] {
                ToolPageView(store: store)
            }
        case .history:
            HistoryView(store: model.history)
        case .settings:
            SettingsView()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<Page?>(
            get: { model.page },
            set: { if let page = $0 { model.page = page } }
        )
        List(selection: selection) {
            ForEach(Page.groups.indices, id: \.self) { index in
                let group = Page.groups[index]
                Section(group.0) {
                    ForEach(group.1) { page in
                        SidebarRow(page: page)
                            .tag(page)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                AppMark(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MadMole")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                    Text("Mac bakım merkezi")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    model.page = .settings
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Page.settings.symbol)
                        Text(Page.settings.title)
                        Spacer()
                        Text("v\(Engine.appVersion)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(model.page == .settings ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SidebarRow: View {
    let page: Page

    var body: some View {
        Label {
            Text(page.title)
                .font(.system(size: 13, weight: .medium))
        } icon: {
            IconTile(symbol: page.symbol, tint: page.tint, size: 22)
        }
        .padding(.vertical, 2)
    }
}

/// The app's mark: a mole-ish sparkle on a gradient tile, drawn in code so
/// there is no image asset to keep in sync.
struct AppMark: View {
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [Theme.indigo, Theme.purple, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: Theme.purple.opacity(0.35), radius: 4, y: 2)
    }
}

private struct EngineMissingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Mole motoru bulunamadı", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Uygulama paketi eksik görünüyor. Depo kökünde scripts/build_app.sh betiğini çalıştırarak MadMole.app'i yeniden oluşturun.\n\nAranan konum: \(Engine.rootURL.path)")
        }
    }
}
