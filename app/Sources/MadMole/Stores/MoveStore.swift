import Foundation
import Observation

/// "Move to an external disk": copy with ditto, compare every file byte for
/// byte, and only when nothing is missing or different move the original to
/// the Trash through the engine's `mole_delete` funnel.
@MainActor
@Observable
final class MoveStore {
    enum Phase: Equatable {
        case idle
        case checking
        case copying
        case verifying
        case trashing
        case done
        case failed(String)
    }

    var source: URL?
    var volumes: [ExternalVolume] = []
    var volume: ExternalVolume?
    /// A folder on `volume`; nil means the volume's top level.
    var folder: URL?
    private(set) var sourceBytes: Int64?
    private(set) var isMeasuring = false
    private(set) var phase: Phase = .idle {
        didSet {
            let order: [Phase] = [.checking, .copying, .verifying, .trashing]
            if let index = order.firstIndex(of: phase) { currentStep = index }
        }
    }
    /// The step the last run reached: 0 checks, 1 copy, 2 compare, 3 Trash.
    private(set) var currentStep = -1
    private(set) var problems: [SafeMove.Problem] = []
    private(set) var refusal: String?
    private(set) var report: SafeMove.VerifyReport?
    private(set) var copiedBytes: Int64 = 0
    private(set) var comparedBytes: Int64 = 0
    private(set) var startedAt: Date?
    private(set) var copyTarget: URL?
    private(set) var originalTrashed = false
    var console: ConsoleLog?
    var helper = EngineHelper()
    private var task: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?

    var destinationFolder: URL? { folder ?? volume?.url }

    var isBusy: Bool {
        switch phase {
        case .checking, .copying, .verifying, .trashing: return true
        default: return false
        }
    }

    func refreshVolumes() {
        volumes = ExternalVolume.mounted()
        if let current = volume {
            volume = volumes.first { $0.id == current.id }
            if volume == nil { folder = nil }
        }
    }

    func choose(source url: URL) {
        guard !isBusy else { return }
        source = url
        resetResult()
        measure()
    }

    func choose(volume: ExternalVolume?) {
        self.volume = volume
        folder = nil
        resetResult()
    }

    func choose(folder url: URL) {
        guard let volume, url.standardizedFileURL.path == volume.url.path
            || url.standardizedFileURL.path.hasPrefix(volume.url.path + "/") else {
            refusal = "Seçtiğiniz klasör \(volume?.name ?? "seçili disk") üzerinde değil."
            return
        }
        folder = url
        resetResult()
    }

    func resetResult() {
        guard !isBusy else { return }
        phase = .idle
        currentStep = -1
        problems = []
        refusal = nil
        report = nil
        copyTarget = nil
        originalTrashed = false
        copiedBytes = 0
        comparedBytes = 0
    }

    private func measure() {
        guard let source else { return }
        sourceBytes = nil
        isMeasuring = true
        measureTask?.cancel()
        let path = source.path
        measureTask = Task {
            let bytes = await Task.detached(priority: .userInitiated) { DiskUsage.allocatedSize(of: path) }.value
            if self.source?.path == path {
                self.sourceBytes = bytes
                self.isMeasuring = false
            }
        }
    }

    /// Checks everything that can be checked without writing, then runs the
    /// whole copy, verify and Trash sequence.
    func start() {
        guard !isBusy, let source, let folder = destinationFolder else { return }
        resetResult()
        phase = .checking
        startedAt = Date()
        let target = SafeMove.destination(for: source, in: folder)
        copyTarget = target
        task = Task {
            // Copying and comparing tens of gigabytes takes a while; keep the
            // Mac awake (idle sleep only, the display may turn off).
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "MadMole dosyaları harici diske taşıyor")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            await self.run(source: source, folder: folder, target: target)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(source: URL, folder: URL, target: URL) async {
        do {
            // 1. The engine's protection rules, before anything is copied.
            let verdict = try await helper.check([source.path]).first
            guard verdict?.verdict == .allowed else {
                if case let .refused(reason)? = verdict?.verdict {
                    fail("Taşınamaz: \(EngineHelper.describe(reason: reason)). Hiçbir şey kopyalanmadı.")
                } else {
                    fail("Motor bu öğe için cevap vermedi. Hiçbir şey kopyalanmadı.")
                }
                return
            }
            let bytes: Int64
            if let known = sourceBytes {
                bytes = known
            } else {
                let path = source.path
                bytes = await Task.detached { DiskUsage.allocatedSize(of: path) }.value
                sourceBytes = bytes
            }
            problems = SafeMove.preflight(source: source, folder: folder, sourceBytes: bytes,
                                          availableBytes: ExternalVolume.availableBytes(at: folder))
            guard problems.isEmpty else {
                phase = .idle
                currentStep = 0
                return
            }

            // 2. Copy.
            phase = .copying
            console?.append("ditto \(source.path) → \(target.path)", source: "move")
            let freeAtStart = ExternalVolume.availableBytes(at: folder) ?? 0
            let progressTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let free = ExternalVolume.availableBytes(at: folder) {
                        self.copiedBytes = min(max(freeAtStart - free, 0), bytes)
                    }
                }
            }
            defer { progressTask.cancel() }
            try await SafeMove.copy(from: source, to: target)
            progressTask.cancel()
            copiedBytes = bytes
            try Task.checkCancellation()

            // 3. Byte-for-byte comparison.
            phase = .verifying
            let sink: @Sendable (Int64) -> Void = { value in
                Task { @MainActor in self.comparedBytes = value }
            }
            let result = try await Task.detached(priority: .userInitiated) {
                try SafeMove.verify(source: source, copy: target, progress: sink)
            }.value
            report = result
            console?.append("Karşılaştırma: \(result.files) dosya, \(result.missing) eksik, \(result.different) farklı, \(result.unreadable) okunamadı", source: "move")
            guard result.isIdentical else {
                fail("Kopya aslıyla birebir aynı değil. Asıl dosyalara dokunulmadı; diskteki kopyayı inceleyip kendiniz silebilirsiniz.")
                return
            }

            // 4. Original to the Trash, through mole_delete.
            phase = .trashing
            let outcome = try await helper.trash([source.path], command: "madmole-move").first
            switch outcome?.verdict {
            case .allowed?:
                originalTrashed = true
                phase = .done
                console?.append("Aslı Çöp'e taşındı: \(source.path)", source: "move")
            case let .refused(reason)?:
                fail("Kopya doğrulandı ama aslı Çöp'e taşınamadı: \(EngineHelper.describe(reason: reason)).")
            case let .failed(status)?:
                fail("Kopya doğrulandı ama aslı Çöp'e taşınamadı (motor kodu \(status)). macOS izin vermemiş olabilir; Finder'dan kendiniz taşıyabilirsiniz.")
            case nil:
                fail("Kopya doğrulandı ama motor Çöp'e taşıma için cevap vermedi.")
            }
        } catch is CancellationError {
            fail("Durduruldu. Asıl dosyalara dokunulmadı; diskte yarım kalan kopyayı kendiniz silebilirsiniz.")
        } catch {
            if Task.isCancelled {
                fail("Durduruldu. Asıl dosyalara dokunulmadı; diskte yarım kalan kopyayı kendiniz silebilirsiniz.")
            } else {
                fail("İşlem durdu: \(error.localizedDescription). Asıl dosyalara dokunulmadı.")
            }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        console?.append(message, source: "move")
    }
}
