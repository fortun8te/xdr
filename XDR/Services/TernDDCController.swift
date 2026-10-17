import Foundation
import CoreGraphics
import AppKit
import Darwin

enum TernDisplayIdentity {
    static func matches(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(id) == 0 && CGDisplayVendorNumber(id) == 0x4a8b
            && CGDisplayModelNumber(id) == 0xd195 && CGDisplaySerialNumber(id) == 0x01010101
    }
    static func percent(_ value: Double) -> Int {
        guard value.isFinite else { return 100 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }
}

private final class DDCJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// One hardware operation is in flight and only the newest slider value waits.
/// Continuous dragging is throttled, not debounced until the gesture stops.
@MainActor
final class TernDDCController {
    typealias CommandRunner = @Sendable ([String]) throws -> String
    private let queue = DispatchQueue(label: "com.xdr.tern-ddc", qos: .userInitiated)
    private let resolveDisplay: (CGDirectDisplayID) -> String?
    private let commandRunner: CommandRunner
    private let persistBrightness: (Int) throws -> Void
    private let minimumWriteInterval: TimeInterval
    private var pending: [CGDirectDisplayID: Int] = [:]
    private var revisions: [CGDirectDisplayID: UInt64] = [:]
    private var workers: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var jobs: [CGDirectDisplayID: DDCJob] = [:]
    private var refreshes: [CGDirectDisplayID: DDCJob] = [:]
    private var cooldowns: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var urgent: Set<CGDirectDisplayID> = []
    private var lastWrite: [CGDirectDisplayID: TimeInterval] = [:]
    private var confirmed: [CGDirectDisplayID: Double] = [:]
    private var stopped = false
    private(set) var levels: [CGDirectDisplayID: Double] = [:]
    var onResult: ((CGDirectDisplayID, Result<Double, Error>) -> Void)?

    init(resolveDisplay: @escaping (CGDirectDisplayID) -> String? = TernDDCController.displayUUID,
         commandRunner: @escaping CommandRunner = { try TernDDCController.runBundled($0) },
         persistBrightness: @escaping (Int) throws -> Void = { try TernDDCController.persist($0) },
         minimumWriteInterval: TimeInterval = 0.08) {
        self.resolveDisplay = resolveDisplay
        self.commandRunner = commandRunner
        self.persistBrightness = persistBrightness
        self.minimumWriteInterval = minimumWriteInterval
    }

    nonisolated static var presetURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tern Controls/defaults.json")
    }
    func brightness(for id: CGDirectDisplayID) -> Double { levels[id] ?? 1 }

    func refresh(_ id: CGDirectDisplayID) {
        guard !stopped, workers[id] == nil, refreshes[id] == nil,
              let uuid = resolveDisplay(id) else { return }
        let revision = revisions[id, default: 0]
        let job = DDCJob()
        refreshes[id] = job
        Task { [weak self] in
            guard let self else { return }
            defer { if self.refreshes[id] === job { self.refreshes[id] = nil } }
            do {
                let text = try await self.execute(["display", uuid, "get", "luminance"], job: job)
                guard !self.stopped, !job.isCancelled,
                      self.revisions[id, default: 0] == revision, self.workers[id] == nil else { return }
                let actual = try Self.parse(text)
                self.confirmed[id] = actual; self.levels[id] = actual
                self.onResult?(id, .success(actual))
            } catch {
                guard !self.stopped, !job.isCancelled,
                      self.revisions[id, default: 0] == revision, self.workers[id] == nil else { return }
                self.onResult?(id, .failure(error))
            }
        }
    }

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard !stopped, value.isFinite, resolveDisplay(id) != nil else { return }
        let wanted = TernDisplayIdentity.percent(value)
        if levels[id] == Double(wanted) / 100,
           (workers[id] != nil || confirmed[id] == Double(wanted) / 100) { return }
        revisions[id, default: 0] &+= 1
        levels[id] = Double(wanted) / 100 // hotkeys accumulate against the latest user intent
        pending[id] = wanted
        refreshes[id]?.cancel()
        guard workers[id] == nil else { return }
        let job = DDCJob(); jobs[id] = job
        workers[id] = Task { [weak self] in guard let self else { return }; await self.drain(id, job: job) }
    }

    /// Release bypasses any remaining throttle delay; an in-flight write is never duplicated.
    func finishAdjustment(for id: CGDirectDisplayID) {
        urgent.insert(id)
        cooldowns[id]?.cancel()
    }

    private func drain(_ id: CGDirectDisplayID, job: DDCJob) async {
        defer { workers[id] = nil; jobs[id] = nil; cooldowns[id] = nil; urgent.remove(id) }
        while !stopped, !job.isCancelled, !Task.isCancelled, pending[id] != nil {
            if !urgent.contains(id), let last = lastWrite[id] {
                let remaining = minimumWriteInterval - (ProcessInfo.processInfo.systemUptime - last)
                if remaining > 0 {
                    let cooldown = Task { do { try await Task.sleep(for: .seconds(remaining)) } catch {} }
                    cooldowns[id] = cooldown
                    await cooldown.value
                    cooldowns[id] = nil
                }
            }
            urgent.remove(id)
            guard !stopped, !job.isCancelled, !Task.isCancelled,
                  let wanted = pending.removeValue(forKey: id), let uuid = resolveDisplay(id) else { return }
            let revision = revisions[id, default: 0]
            do {
                _ = try await execute(["display", uuid, "set", "luminance", String(wanted)], job: job)
                lastWrite[id] = ProcessInfo.processInfo.systemUptime
                // Intermediate drag writes need no extra process/read: verify the settled latest value.
                if pending[id] != nil { continue }
                let text = try await execute(["display", uuid, "get", "luminance"], job: job)
                let actual = try Self.parse(text)
                confirmed[id] = actual
                guard !stopped, !job.isCancelled, !Task.isCancelled else { return }
                guard revisions[id, default: 0] == revision, pending[id] == nil else { continue }
                guard Int((actual * 100).rounded()) == wanted else {
                    throw Self.error("The monitor did not confirm the brightness. Try again.")
                }
                try persistBrightness(wanted)
                levels[id] = actual
                onResult?(id, .success(actual))
            } catch {
                guard !stopped, !job.isCancelled, !Task.isCancelled else { return }
                if revisions[id, default: 0] != revision || pending[id] != nil { continue }
                levels[id] = confirmed[id] ?? 1
                onResult?(id, .failure(error))
            }
        }
    }

    func shutdown() {
        stopped = true
        for job in jobs.values { job.cancel() }
        for job in refreshes.values { job.cancel() }
        for task in workers.values { task.cancel() }
        for task in cooldowns.values { task.cancel() }
        pending.removeAll(); refreshes.removeAll()
    }

    nonisolated static func persist(_ percent: Int, at url: URL = presetURL) throws {
        var settings = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url)))
            ?? ["contrast": 80, "red": 50, "green": 50, "blue": 50, "volume": 50]
        settings["luminance"] = min(max(percent, 0), 100)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }

    private func execute(_ args: [String], job: DDCJob) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [commandRunner] in
                guard !job.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                do { continuation.resume(returning: try commandRunner(args)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private nonisolated static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard TernDisplayIdentity.matches(id), let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
    private nonisolated static func parse(_ text: String) throws -> Double {
        guard let actual = Int(text), (0...100).contains(actual) else { throw error("Could not verify monitor brightness.") }
        return Double(actual) / 100
    }
    private nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "TernDDC", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private nonisolated static func runBundled(_ args: [String]) throws -> String {
        guard let tool = Bundle.main.url(forResource: "m1ddc", withExtension: nil) else {
            throw error("The monitor control tool is missing.")
        }
        let process = Process(); let pipe = Pipe(); let ended = DispatchSemaphore(value: 0)
        process.executableURL = tool; process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        // Block this background worker once, rather than waking every 10 ms to poll isRunning.
        if ended.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + 0.1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = ended.wait(timeout: .now() + 0.2) }
            throw error("The monitor is still waking. Try again in a moment.")
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else { throw error("Could not reach the monitor hardware. Try again.") }
        return text
    }
}
