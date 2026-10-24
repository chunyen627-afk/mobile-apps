// NOT COMPILED, NOT VISUALLY TESTED: written without Swift/Xcode available.

import Foundation
import MinerStatusCore

enum AppMode: Equatable {
    /// Built-in offline demo. Every launch starts here.
    case demo
    /// Read-only reading of a user-configured source, foreground only.
    case live
}

/// Single source of truth for the views. Live mode never starts on its own: only `startLive`
/// (an explicit user action) connects, and polling stops whenever the app leaves the foreground.
@MainActor
final class AppModel: ObservableObject {
    static let pollIntervals: [TimeInterval] = [15, 30, 60]
    /// How often ages and the 5-minute boundary are re-evaluated between fetches.
    private static let reevaluateEvery: TimeInterval = 5

    @Published private(set) var mode: AppMode = .demo
    @Published private(set) var snapshots: [MachineSnapshot] = []
    @Published private(set) var feedProblem: UpdateProblem?

    // Demo
    @Published private(set) var scenario: DemoScenario = .confirmedMining
    @Published private(set) var demoClock: ClockReading?
    @Published private(set) var demoError: String?
    let demoNotice: String
    private let demo: DemoPlayer?

    // Live
    @Published private(set) var endpoint: SourceEndpoint?
    @Published private(set) var pollInterval: TimeInterval = 30
    @Published private(set) var isPolling = false
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var lastFailure: FetchFailure?
    @Published private(set) var sourceSentDemoData = false

    private var engine = StatusEngine()
    private var clock = SystemClock()
    private var client: StatusFeedClient?
    private var pollTask: Task<Void, Never>?
    private var isFetching = false
    private var isForeground = true

    init() {
        demo = DemoPlayer.loadBundled()
        demoNotice = demo?.notice ?? ""
        selectDemo(.confirmedMining)
    }

    // MARK: - Demo

    func selectDemo(_ scenario: DemoScenario) {
        stopPolling()
        client = nil
        mode = .demo
        self.scenario = scenario
        guard let demo else {
            snapshots = []
            feedProblem = nil
            demoClock = nil
            demoError = "找不到或無法解碼內建示範資料 demo-running.json（需加入 App 資源，且必須標示為 demo）。"
            return
        }
        do {
            let result = try demo.run(scenario)
            snapshots = result.snapshots
            feedProblem = result.feedProblem
            demoClock = result.clock
            demoError = nil
        } catch {
            snapshots = []
            feedProblem = nil
            demoClock = nil
            demoError = "示範資料未通過解碼：\(error.localizedDescription)"
        }
    }

    // MARK: - Live

    /// Explicit user action. Starts from a clean engine so nothing carries over from the demo.
    func startLive(endpoint: SourceEndpoint, pollInterval: TimeInterval) {
        stopPolling()
        mode = .live
        self.endpoint = endpoint
        self.pollInterval = Self.pollIntervals.contains(pollInterval) ? pollInterval : 30
        client = StatusFeedClient(endpoint: endpoint)
        engine = StatusEngine()
        clock = SystemClock()
        snapshots = []
        feedProblem = nil
        lastAttemptAt = nil
        lastSuccessAt = nil
        lastFailure = nil
        sourceSentDemoData = false
        if isForeground { startPolling() }
    }

    func stopLiveAndReturnToDemo() {
        selectDemo(scenario)
    }

    func refreshNow() {
        guard mode == .live, isForeground else { return }
        Task { await fetchOnce() }
    }

    /// Foreground only: leaving the foreground cancels polling; returning fetches immediately.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        guard mode == .live else { return }
        if foreground {
            reevaluate()
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        stopPolling()
        isPolling = true
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await fetchOnce()
            let deadline = ContinuousClock.now + .seconds(pollInterval)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(Self.reevaluateEvery))
                if !Task.isCancelled { reevaluate() }
            }
        }
    }

    private func fetchOnce() async {
        guard let client, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        lastAttemptAt = Date()
        let result = await client.fetch()
        // Drop results that arrive after the user stopped or switched source.
        guard mode == .live, self.client?.endpoint == client.endpoint else { return }
        // Receive time is taken after the response arrived.
        engine.apply(result, at: clock.reading())
        switch result {
        case .success(let feed):
            lastSuccessAt = Date()
            lastFailure = nil
            sourceSentDemoData = feed.isDemo
        case .failure(.cancelled):
            break
        case .failure(let failure):
            lastFailure = failure
        }
        reevaluate()
    }

    private func reevaluate() {
        guard mode == .live else { return }
        snapshots = engine.snapshots(at: clock.reading())
        feedProblem = engine.feedProblem
    }
}
