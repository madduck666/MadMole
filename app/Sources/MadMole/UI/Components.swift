import AppKit
import Charts
import SwiftUI

// MARK: - Icon tile

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.80), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            )
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.35), radius: size * 0.12, y: size * 0.06)
    }
}

// MARK: - Page header

struct PageHeader<Trailing: View>: View {
    let page: Page
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: page.symbol, tint: page.tint, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(page.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(page: Page) {
        self.page = page
        self.trailing = { EmptyView() }
    }
}

// MARK: - Card

/// A rounded group box with an optional header, in the spirit of the
/// header/content/footer boxes popular in SwiftUI Mac utilities.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint: Color = .accentColor
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
            }
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }
}

// MARK: - Ring gauge

struct RingGauge<Label: View>: View {
    let fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 10
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.65), tint], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.01))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
            label()
        }
    }
}

// MARK: - Capsule bar

struct CapsuleBar: View {
    let fraction: Double
    var tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
                    .animation(.easeOut(duration: 0.35), value: fraction)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    var tint: Color
    var maxValue: Double?

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(maxValue ?? max(values.max() ?? 1, 0.0001)))
        .chartLegend(.hidden)
    }
}

// MARK: - Small pieces

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct StatRow: View {
    let title: String
    let value: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.callout)
    }
}

struct BigNumber: View {
    let value: String
    var unit: String?
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A large primary button filled with a page gradient.
struct GradientButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: tint.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The big centered welcome shown before a page has data.
struct HeroPrompt<Actions: View>: View {
    let page: Page
    let title: String
    let message: String
    var bullets: [String] = []
    @ViewBuilder var actions: () -> Actions
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(page.tint.opacity(0.12))
                    .frame(width: 150, height: 150)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                Circle()
                    .fill(page.tint.opacity(0.18))
                    .frame(width: 110, height: 110)
                IconTile(symbol: page.symbol, tint: page.tint, size: 72)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bullets, id: \.self) { bullet in
                        Label(bullet, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(page.tint, .secondary)
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
            HStack(spacing: 12) { actions() }
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An inline progress panel with the latest engine line.
struct WorkingPanel: View {
    let title: String
    var detail: String?
    var tint: Color
    var startedAt: Date?
    /// When output last arrived; after a minute of silence the panel says
    /// what can hold a scan up.
    var lastActivity: Date?
    var note: String?
    var onCancel: (() -> Void)?

    static let quietLimit: TimeInterval = 60

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(tint)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("Geçen süre: \(Int(context.date.timeIntervalSince(startedAt))) sn")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if let lastActivity {
                TimelineView(.periodic(from: lastActivity, by: 5)) { context in
                    let quiet = context.date.timeIntervalSince(lastActivity)
                    if quiet >= Self.quietLimit {
                        QuietScanHint(seconds: Int(quiet))
                    }
                }
            }
            if let onCancel {
                Button("Vazgeç", role: .cancel, action: onCancel)
                    .controlSize(.regular)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when a scan has printed nothing for a while: what usually holds it
/// up, and where to look.
struct QuietScanHint: View {
    let seconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(seconds / 60) dakikadır yeni çıktı yok", systemImage: "hourglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.orange)
            Text("Uygulama klasörleri gibi büyük adımlar bitene kadar satır yazmaz; bu normal olabilir. Ama macOS bir izin penceresi açmışsa tarama sizin cevabınızı bekler: ekranda ya da Dock'ta MadMole'dan bir soru var mı bakın. Güncellemeden sonra Tam Disk Erişimi düşmüşse bu sorular daha sık çıkar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Tam Disk Erişimi") { PrivacyPane.open(.fullDiskAccess) }
                Button("Diğer pencereleri göster") { NSApp.activate(ignoringOtherApps: true); NSApp.arrangeInFront(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.10)))
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let retry {
                Button("Tekrar dene", action: retry)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.12)))
    }
}

/// The file icon Finder shows for a path.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
