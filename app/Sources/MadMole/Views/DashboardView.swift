import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let store: DashboardStore
    @State private var hasFullDiskAccess = Permissions.hasFullDiskAccess

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(page: .dashboard) {
                    LiveIndicator(active: store.isStreaming && store.snapshot != nil)
                }
                if !hasFullDiskAccess {
                    FullDiskAccessBanner {
                        hasFullDiskAccess = Permissions.hasFullDiskAccess
                    }
                }
                if let snapshot = store.snapshot {
                    content(snapshot)
                } else if let error = store.errorMessage {
                    ErrorBanner(message: error) { store.start() }
                } else {
                    WorkingPanel(title: "Sistem bilgileri toplanıyor…", tint: Page.dashboard.tint)
                        .frame(height: 320)
                }
            }
            .padding(24)
        }
        .onAppear {
            store.start()
            hasFullDiskAccess = Permissions.hasFullDiskAccess
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = Permissions.hasFullDiskAccess
        }
        .onDisappear { store.stop() }
    }

    @ViewBuilder
    private func content(_ s: StatusSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            HealthCard(snapshot: s)
            SystemCard(snapshot: s)
        }
        .fixedSize(horizontal: false, vertical: true)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
            CPUCard(cpu: s.cpu, history: store.cpuHistory, gpu: s.gpu?.first)
            MemoryCard(memory: s.memory, history: store.memoryHistory)
            DiskCard(disks: s.disks ?? [], trash: s.trashSize, io: s.diskIo)
            NetworkCard(networks: s.network ?? [], history: s.networkHistory, proxy: s.proxy)
            if let battery = s.batteries?.first {
                BatteryCard(battery: battery, thermal: s.thermal)
            } else if s.thermal != nil {
                ThermalCard(thermal: s.thermal)
            }
            if let devices = s.bluetooth, !devices.isEmpty {
                BluetoothCard(devices: devices)
            }
        }

        if let processes = s.topProcesses, !processes.isEmpty {
            ProcessesCard(processes: processes)
        }
    }
}

// MARK: - Permissions

enum Permissions {
    enum FullDiskAccess {
        case granted
        case denied
        case unknown
    }

    /// Folders and files only Full Disk Access can read, the same probe the
    /// engine uses (`has_full_disk_access` in lib/core/ui.sh) plus the user
    /// TCC database. Existence is visible without access; reading proves it.
    static let probePaths: [String] = [
        "Library/Safari/LocalStorage",
        "Library/Safari",
        "Library/Mail",
        "Library/Messages/chat.db",
        "Library/Application Support/com.apple.TCC/TCC.db",
    ]

    struct ProbeResult {
        let path: String
        let exists: Bool
        let readable: Bool
    }

    static func probe() -> [ProbeResult] {
        let fm = FileManager.default
        return probePaths.map { relative in
            let path = Engine.homeDirectory + "/" + relative
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return ProbeResult(path: path, exists: false, readable: false)
            }
            let readable: Bool
            if isDirectory.boolValue {
                readable = (try? fm.contentsOfDirectory(atPath: path)) != nil
            } else if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                readable = true
            } else {
                readable = false
            }
            return ProbeResult(path: path, exists: true, readable: readable)
        }
    }

    static var fullDiskAccess: FullDiskAccess {
        let results = probe().filter(\.exists)
        if results.isEmpty { return .unknown }
        return results.contains(where: \.readable) ? .granted : .denied
    }

    /// Only a confirmed denial counts as missing; an unknown state does not nag.
    static var hasFullDiskAccess: Bool {
        fullDiskAccess != .denied
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FullDiskAccessBanner: View {
    var recheck: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "lock.shield.fill", tint: Theme.orange, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Tam Disk Erişimi önerilir")
                    .font(.headline)
                Text("MadMole'a Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi'nden izin verirseniz temizlik ve analiz korumalı klasörleri de görebilir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Ayarları Aç") { Permissions.openFullDiskAccessSettings() }
            Button("Tekrar Kontrol Et", action: recheck)
                .buttonStyle(.borderless)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.orange.opacity(0.25)))
    }
}

struct LiveIndicator: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Theme.green : Theme.gray)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse && active ? 1.35 : 1)
                .opacity(pulse && active ? 0.6 : 1)
            Text(active ? "Canlı" : "Bekleniyor")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Cards

private struct HealthCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: StatusSnapshot

    var body: some View {
        let score = snapshot.healthScore ?? 0
        let tint = Theme.health(score)
        Card(title: "Sistem Sağlığı", symbol: "heart.text.square.fill", tint: tint) {
            HStack(alignment: .center, spacing: 20) {
                RingGauge(fraction: Double(score) / 100, tint: tint, lineWidth: 12) {
                    VStack(spacing: 0) {
                        Text("\(score)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("/ 100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 10) {
                    Text(healthTitle(score))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = snapshot.healthScoreMsg, !message.isEmpty {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button {
                    model.page = .clean
                } label: {
                    Label("Temizle", systemImage: Page.clean.symbol)
                }
                .buttonStyle(GradientButtonStyle(tint: Page.clean.tint))
                Button {
                    model.page = .optimize
                } label: {
                    Label("Optimize Et", systemImage: Page.optimize.symbol)
                }
                .controlSize(.large)
                Spacer(minLength: 0)
            }
        }
    }

    private func healthTitle(_ score: Int) -> String {
        switch score {
        case 80...: return "Mac'iniz harika durumda"
        case 60..<80: return "İyi durumda"
        case 40..<60: return "Dikkat gerekiyor"
        default: return "Bakım zamanı"
        }
    }
}

private struct SystemCard: View {
    let snapshot: StatusSnapshot

    var body: some View {
        let hw = snapshot.hardware
        Card(title: snapshot.host ?? "Bu Mac", symbol: "laptopcomputer", tint: Theme.indigo) {
            VStack(spacing: 7) {
                StatRow(title: "Model", value: hw?.model ?? "—", symbol: "desktopcomputer")
                StatRow(title: "Yonga", value: hw?.cpuModel ?? "—", symbol: "cpu")
                StatRow(title: "Bellek", value: hw?.totalRam ?? "—", symbol: "memorychip")
                StatRow(title: "Disk", value: hw?.diskSize ?? "—", symbol: "internaldrive")
                StatRow(title: "Sistem", value: hw?.osVersion ?? snapshot.platform ?? "—", symbol: "apple.logo")
                StatRow(title: "Açık kalma", value: snapshot.uptime ?? "—", symbol: "clock")
                StatRow(title: "Süreçler", value: snapshot.procs.map { "\($0)" } ?? "—", symbol: "list.bullet.rectangle")
            }
        }
        .frame(maxWidth: 380)
    }
}

private struct CPUCard: View {
    let cpu: StatusSnapshot.CPUStatus?
    let history: [Double]
    let gpu: StatusSnapshot.GPUStatus?

    var body: some View {
        let usage = cpu?.usage ?? 0
        Card(title: "İşlemci", symbol: "cpu.fill", tint: Theme.blue) {
            HStack(alignment: .firstTextBaseline) {
                BigNumber(value: String(format: "%.0f", usage), unit: "%", tint: Theme.level(usage / 100))
                Spacer()
                if let p = cpu?.pCoreCount, let e = cpu?.eCoreCount, p + e > 0 {
                    Text("\(p) performans · \(e) verimlilik")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let cores = cpu?.logicalCpu {
                    Text("\(cores) çekirdek")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Sparkline(values: history.isEmpty ? [usage] : history, tint: Theme.blue, maxValue: 100)
                .frame(height: 54)
            if let cores = cpu?.perCore, !cores.isEmpty, cores.count <= 32 {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { _, value in
                        GeometryReader { proxy in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.level(value / 100).opacity(0.85))
                                    .frame(height: max(2, proxy.size.height * min(value, 100) / 100))
                            }
                        }
                    }
                }
                .frame(height: 26)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
            }
            StatRow(title: "Yük (1/5/15 dk)",
                    value: String(format: "%.2f · %.2f · %.2f", cpu?.load1 ?? 0, cpu?.load5 ?? 0, cpu?.load15 ?? 0))
            if let gpu, let gpuUsage = gpu.usage, gpuUsage >= 0 {
                StatRow(title: gpu.name ?? "GPU", value: String(format: "%.0f%%", gpuUsage))
            }
        }
    }
}

private struct MemoryCard: View {
    let memory: StatusSnapshot.MemoryStatus?
    let history: [Double]

    var body: some View {
        let percent = memory?.usedPercent ?? 0
        Card(title: "Bellek", symbol: "memorychip.fill", tint: Theme.purple) {
            HStack(alignment: .firstTextBaseline) {
                BigNumber(value: String(format: "%.0f", percent), unit: "%", tint: Theme.level(percent / 100, warn: 0.80, critical: 0.92))
                Spacer()
                if let pressure = memory?.pressure, !pressure.isEmpty {
                    Badge(text: pressureLabel(pressure), tint: pressureTint(pressure))
                }
            }
            Sparkline(values: history.isEmpty ? [percent] : history, tint: Theme.purple, maxValue: 100)
                .frame(height: 54)
            StatRow(title: "Kullanılan", value: "\(TextUtils.formatBytes(memory?.used ?? 0)) / \(TextUtils.formatBytes(memory?.total ?? 0))")
            StatRow(title: "Kullanılabilir", value: TextUtils.formatBytes(memory?.available ?? 0))
            if let swap = memory?.swapUsed, swap > 0 {
                StatRow(title: "Takas (swap)", value: TextUtils.formatBytes(swap))
            }
        }
    }

    private func pressureLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "normal": return "Basınç: normal"
        case "warn", "warning": return "Basınç: yüksek"
        case "critical": return "Basınç: kritik"
        default: return value
        }
    }

    private func pressureTint(_ value: String) -> Color {
        switch value.lowercased() {
        case "normal": return Theme.green
        case "critical": return Theme.red
        default: return Theme.orange
        }
    }
}

private struct DiskCard: View {
    let disks: [StatusSnapshot.DiskStatus]
    let trash: UInt64?
    let io: StatusSnapshot.DiskIO?

    var body: some View {
        Card(title: "Depolama", symbol: "internaldrive.fill", tint: Theme.orange) {
            ForEach(disks.filter { ($0.total ?? 0) > 0 }) { disk in
                let fraction = (disk.usedPercent ?? 0) / 100
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: disk.external == true ? "externaldrive.fill" : "internaldrive")
                            .foregroundStyle(.secondary)
                        Text(diskName(disk))
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(TextUtils.formatBytes((disk.total ?? 0) &- (disk.used ?? 0))) boş")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    CapsuleBar(fraction: fraction, tint: Theme.level(fraction, warn: 0.80, critical: 0.92))
                    Text("\(TextUtils.formatBytes(disk.used ?? 0)) / \(TextUtils.formatBytes(disk.total ?? 0)) kullanımda")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let trash, trash > 0 {
                StatRow(title: "Çöp Sepeti", value: TextUtils.formatBytes(trash), symbol: "trash")
            }
            if let io {
                StatRow(title: "Okuma / Yazma",
                        value: "\(TextUtils.formatRate(io.readRate ?? 0)) · \(TextUtils.formatRate(io.writeRate ?? 0))",
                        symbol: "arrow.up.arrow.down")
            }
        }
    }

    private func diskName(_ disk: StatusSnapshot.DiskStatus) -> String {
        guard let mount = disk.mount else { return disk.device ?? "Disk" }
        if mount == "/" || mount == "/System/Volumes/Data" { return "Macintosh HD" }
        return (mount as NSString).lastPathComponent
    }
}

private struct NetworkCard: View {
    let networks: [StatusSnapshot.NetworkStatus]
    let history: StatusSnapshot.NetworkHistory?
    let proxy: StatusSnapshot.ProxyStatus?

    var body: some View {
        let rx = networks.reduce(0) { $0 + ($1.rxRateMbs ?? 0) }
        let tx = networks.reduce(0) { $0 + ($1.txRateMbs ?? 0) }
        Card(title: "Ağ", symbol: "network", tint: Theme.teal) {
            HStack(spacing: 24) {
                rate(symbol: "arrow.down.circle.fill", title: "İndirme", value: rx, tint: Theme.teal)
                rate(symbol: "arrow.up.circle.fill", title: "Yükleme", value: tx, tint: Theme.pink)
            }
            if let rxHistory = history?.rxHistory, rxHistory.count > 1 {
                ZStack {
                    Sparkline(values: rxHistory, tint: Theme.teal)
                    if let txHistory = history?.txHistory, txHistory.count > 1 {
                        Sparkline(values: txHistory, tint: Theme.pink, maxValue: max(rxHistory.max() ?? 0, txHistory.max() ?? 0, 0.0001))
                            .opacity(0.8)
                    }
                }
                .frame(height: 48)
            }
            ForEach(networks.filter { !($0.ip ?? "").isEmpty }.prefix(3)) { net in
                StatRow(title: net.name ?? "Arayüz", value: net.ip ?? "", symbol: "wifi")
            }
            if let proxy, proxy.enabled == true {
                StatRow(title: "Vekil sunucu", value: [proxy.type, proxy.host].compactMap { $0 }.joined(separator: " "), symbol: "lock.shield")
            }
        }
    }

    private func rate(symbol: String, title: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(TextUtils.formatRate(value))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}

private struct BatteryCard: View {
    let battery: StatusSnapshot.BatteryStatus
    let thermal: StatusSnapshot.ThermalStatus?

    var body: some View {
        let percent = battery.percent ?? 0
        let tint = percent <= 20 ? Theme.red : (percent <= 40 ? Theme.orange : Theme.green)
        Card(title: "Pil ve Isı", symbol: "battery.100percent.bolt", tint: Theme.green) {
            HStack(spacing: 18) {
                RingGauge(fraction: percent / 100, tint: tint, lineWidth: 8) {
                    Text(String(format: "%.0f%%", percent))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 5) {
                    if let status = battery.status { StatRow(title: "Durum", value: status) }
                    if let left = battery.timeLeft, !left.isEmpty { StatRow(title: "Kalan", value: left) }
                    if let health = battery.health, !health.isEmpty { StatRow(title: "Sağlık", value: health) }
                }
            }
            if let cycles = battery.cycleCount, cycles > 0 {
                StatRow(title: "Şarj döngüsü", value: "\(cycles)", symbol: "arrow.triangle.2.circlepath")
            }
            if let capacity = battery.capacity, capacity > 0 {
                StatRow(title: "Azami kapasite", value: "%\(capacity)", symbol: "battery.75percent")
            }
            ThermalRows(thermal: thermal)
        }
    }
}

private struct ThermalCard: View {
    let thermal: StatusSnapshot.ThermalStatus?

    var body: some View {
        Card(title: "Isı ve Güç", symbol: "thermometer.medium", tint: Theme.red) {
            ThermalRows(thermal: thermal)
        }
    }
}

private struct ThermalRows: View {
    let thermal: StatusSnapshot.ThermalStatus?

    var body: some View {
        if let thermal {
            if let cpu = thermal.cpuTemp, cpu > 0 {
                StatRow(title: "İşlemci sıcaklığı", value: String(format: "%.0f °C", cpu), symbol: "thermometer.medium")
            }
            if let battery = thermal.batteryTemp, battery > 0 {
                StatRow(title: "Pil sıcaklığı", value: String(format: "%.0f °C", battery), symbol: "thermometer.low")
            }
            if let fan = thermal.fanSpeed, fan > 0 {
                StatRow(title: "Fan", value: "\(fan) RPM", symbol: "fan")
            }
            if let power = thermal.systemPower, power > 0 {
                StatRow(title: "Sistem gücü", value: String(format: "%.1f W", power), symbol: "bolt")
            }
        }
    }
}

private struct BluetoothCard: View {
    let devices: [StatusSnapshot.BluetoothDevice]

    var body: some View {
        Card(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", tint: Theme.blue) {
            ForEach(devices.prefix(6)) { device in
                HStack {
                    Circle()
                        .fill(device.connected == true ? Theme.green : Theme.gray.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(device.name ?? "Aygıt")
                    Spacer()
                    if let battery = device.battery, !battery.isEmpty {
                        Text(battery).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.callout)
            }
        }
    }
}

private struct ProcessesCard: View {
    let processes: [StatusSnapshot.ProcessInfoRow]

    var body: some View {
        let maxCPU = max(processes.map { $0.cpu ?? 0 }.max() ?? 1, 1)
        Card(title: "En Çok Kaynak Kullananlar", symbol: "list.number", tint: Theme.pink) {
            VStack(spacing: 8) {
                ForEach(processes.prefix(8)) { process in
                    HStack(spacing: 10) {
                        Text(process.name ?? "?")
                            .lineLimit(1)
                            .frame(width: 200, alignment: .leading)
                        CapsuleBar(fraction: (process.cpu ?? 0) / maxCPU, tint: Theme.pink, height: 6)
                        Text(String(format: "%.1f%%", process.cpu ?? 0))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                        Text(process.memoryBytes.map { TextUtils.formatBytes($0) } ?? String(format: "%.1f%%", process.memory ?? 0))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
