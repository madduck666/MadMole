import Foundation

// MARK: - Status (`status-go --json` / `--watch`)

/// One metrics snapshot. Every field is optional so a newer or older engine
/// that adds or drops a field never breaks decoding.
struct StatusSnapshot: Decodable {
    var collectedAt: String?
    var host: String?
    var platform: String?
    var uptime: String?
    var uptimeSeconds: UInt64?
    var procs: UInt64?
    var hardware: HardwareInfo?
    var healthScore: Int?
    var healthScoreMsg: String?
    var cpu: CPUStatus?
    var gpu: [GPUStatus]?
    var memory: MemoryStatus?
    var disks: [DiskStatus]?
    var trashSize: UInt64?
    var diskIo: DiskIO?
    var network: [NetworkStatus]?
    var networkHistory: NetworkHistory?
    var proxy: ProxyStatus?
    var batteries: [BatteryStatus]?
    var thermal: ThermalStatus?
    var bluetooth: [BluetoothDevice]?
    var topProcesses: [ProcessInfoRow]?

    struct HardwareInfo: Decodable {
        var model: String?
        var cpuModel: String?
        var totalRam: String?
        var diskSize: String?
        var osVersion: String?
        var refreshRate: String?
    }

    struct CPUStatus: Decodable {
        var usage: Double?
        var perCore: [Double]?
        var load1: Double?
        var load5: Double?
        var load15: Double?
        var coreCount: Int?
        var logicalCpu: Int?
        var pCoreCount: Int?
        var eCoreCount: Int?
    }

    struct GPUStatus: Decodable {
        var name: String?
        var usage: Double?
        var coreCount: Int?
        var note: String?
    }

    struct MemoryStatus: Decodable {
        var used: UInt64?
        var total: UInt64?
        var available: UInt64?
        var usedPercent: Double?
        var swapUsed: UInt64?
        var swapTotal: UInt64?
        var cached: UInt64?
        var pressure: String?
    }

    struct DiskStatus: Decodable, Identifiable {
        var mount: String?
        var device: String?
        var used: UInt64?
        var total: UInt64?
        var usedPercent: Double?
        var fstype: String?
        var external: Bool?
        var purgeable: UInt64?
        var id: String { (mount ?? "") + (device ?? "") }
    }

    struct DiskIO: Decodable {
        var readRate: Double?
        var writeRate: Double?
    }

    struct NetworkStatus: Decodable, Identifiable {
        var name: String?
        var rxRateMbs: Double?
        var txRateMbs: Double?
        var ip: String?
        var id: String { name ?? "?" }
    }

    struct NetworkHistory: Decodable {
        var rxHistory: [Double]?
        var txHistory: [Double]?
    }

    struct ProxyStatus: Decodable {
        var enabled: Bool?
        var type: String?
        var host: String?
    }

    struct BatteryStatus: Decodable {
        var percent: Double?
        var status: String?
        var timeLeft: String?
        var health: String?
        var cycleCount: Int?
        var capacity: Int?
    }

    struct ThermalStatus: Decodable {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var batteryTemp: Double?
        var fanSpeed: Int?
        var fanCount: Int?
        var systemPower: Double?
        var adapterPower: Double?
        var batteryPower: Double?
    }

    struct BluetoothDevice: Decodable, Identifiable {
        var name: String?
        var connected: Bool?
        var battery: String?
        var id: String { name ?? "?" }
    }

    struct ProcessInfoRow: Decodable, Identifiable {
        var pid: Int?
        var name: String?
        var command: String?
        var cpu: Double?
        var memory: Double?
        var memoryBytes: UInt64?
        var id: Int { pid ?? 0 }
    }
}

// MARK: - Analyze (`analyze-go --json`)

struct AnalyzeResult: Decodable {
    var path: String
    var overview: Bool?
    var entries: [AnalyzeEntry]?
    var largeFiles: [AnalyzeFile]?
    var totalSize: Int64?
    var totalFiles: Int64?
}

struct AnalyzeEntry: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var size: Int64
    var isDir: Bool?
    var insight: Bool?
    var cleanable: Bool?
    var lastAccess: String?
    var id: String { path }
}

struct AnalyzeFile: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var size: Int64
    var id: String { path }
}

struct TrashReport: Decodable {
    struct Row: Decodable, Identifiable {
        var path: String
        var ok: Bool
        var error: String?
        var id: String { path }
    }

    var results: [Row]
    var moved: Int
    var failed: Int
    var logWarning: String?
}

// MARK: - Uninstall (`mole uninstall --list`, JSON when piped)

struct InstalledApp: Decodable, Identifiable, Hashable {
    var name: String
    var bundleId: String
    var source: String
    var uninstallName: String
    var path: String
    var size: String

    var id: String { path }
    var sizeBytes: Int64 { TextUtils.parseSize(size) ?? 0 }
    var isHomebrew: Bool { source == "Homebrew" }
}

// MARK: - History (`mole history --json`)

struct HistoryLog: Decodable {
    struct Logs: Decodable {
        var operations: String?
        var deletions: String?
    }

    struct Actions: Decodable {
        var removed: Int?
        var trashed: Int?
        var skipped: Int?
        var failed: Int?
        var rebuilt: Int?
        var other: Int?
    }

    struct Session: Decodable, Identifiable {
        var command: String?
        var runId: String?
        var startedAt: String?
        var endedAt: String?
        var items: Int?
        var size: String?
        var operationCount: Int?
        var failedTasks: Int?
        var actions: Actions?
        var id: String { (runId ?? "") + (startedAt ?? "") + (command ?? "") }
    }

    struct Deletion: Decodable, Identifiable {
        var timestamp: String?
        var mode: String?
        var status: String?
        var sizeKb: Int64?
        var path: String?
        var id: String { (timestamp ?? "") + (path ?? "") }
    }

    var logs: Logs?
    var sessions: [Session]?
    var deletions: [Deletion]?
}

extension JSONDecoder {
    static var engine: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
