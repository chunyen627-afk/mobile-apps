// NOT COMPILED, NOT VISUALLY TESTED: written without Swift/Xcode available.

import Foundation
import MinerStatusCore

/// The user's earnings settings, stored only on this device. Per-machine values override the
/// source's default (`earnings.electricityBilled`) and the default extra load.
struct EarningsSettings: Codable, Equatable {
    static let defaultExtraWatts: Double = 60

    var tariff = TouTariff.taipowerSimpleTwoStage
    /// Use the rates the source published (Taipower open data) instead of `tariff` when available.
    var useSourceTariff = true
    var billed: [String: Bool] = [:]
    var extraWatts: [String: Double] = [:]

    private static let key = "earningsSettings"

    enum CodingKeys: String, CodingKey {
        case tariff, useSourceTariff, billed, extraWatts
    }

    init() {}

    /// Keys added in later versions may be missing from what an older version saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tariff = try c.decodeIfPresent(TouTariff.self, forKey: .tariff) ?? .taipowerSimpleTwoStage
        useSourceTariff = try c.decodeIfPresent(Bool.self, forKey: .useSourceTariff) ?? true
        billed = try c.decodeIfPresent([String: Bool].self, forKey: .billed) ?? [:]
        extraWatts = try c.decodeIfPresent([String: Double].self, forKey: .extraWatts) ?? [:]
    }

    static func load() -> EarningsSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(EarningsSettings.self, from: data)
        else { return EarningsSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The last tariff the source published, kept so the rates and days off still apply in demo mode
/// and after a restart.
enum SourceTariffStore {
    private static let key = "sourceTariff"

    static func load() -> TariffReport? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(TariffReport.self, from: $0) }
    }

    static func save(_ report: TariffReport) {
        if let data = try? JSONEncoder().encode(report) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct ControlNotice: Equatable {
    let machineId: String
    let text: String
    let succeeded: Bool
}

enum AppMode: Equatable {
    /// Built-in offline demo. Every launch starts here.
    case demo
    /// Read-only reading of a user-configured source, foreground only.
    case live
}

/// Remembers that the user is reading a live source. iOS ends an app that stays in the background
/// for a while; without this, coming back meant a fresh launch in the demo (reported 2026-10-26).
/// Set by `startLive`, cleared only when the user stops reading and returns to the demo.
enum LiveResume {
    static let key = "resumeLive"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The saved source to reconnect to at launch, or nil when the user was not reading one or the
    /// saved URL is no longer valid.
    static func savedSource() -> (endpoint: SourceEndpoint, pollInterval: TimeInterval)? {
        guard enabled, let text = UserDefaults.standard.string(forKey: "sourceURL") else { return nil }
        guard let endpoint = try? SourceEndpoint(validating: text) else { return nil }
        let seconds = (UserDefaults.standard.object(forKey: "pollIntervalSeconds") as? Int) ?? 30
        return (endpoint, TimeInterval(seconds))
    }
}

/// Single source of truth for the views. Every launch begins in the demo; live mode starts only
/// from `startLive` (the user's action, or a relaunch while the user was still reading a source,
/// see `LiveResume`), and polling stops whenever the app leaves the foreground.
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
    /// Set when a live machine turns from green to another light; cleared when the user dismisses it.
    @Published private(set) var attentionAlert: String?

    // Control (start/stop for machines the source marks as controllable)
    @Published private(set) var hasControlToken = false
    /// False when the Keychain refused the password; it then works only until the app quits.
    @Published private(set) var controlTokenPersisted = true
    @Published private(set) var controlInFlight: String?
    @Published private(set) var controlNotice: ControlNotice?
    private var controlToken: String?

    // Earnings
    @Published private(set) var market: MarketReport?
    /// The source's running total of estimated earnings; nil when it sends none.
    @Published private(set) var cumulative: CumulativeReport?
    @Published private(set) var sourceTariff: TariffReport? = SourceTariffStore.load()
    /// The source's mine-or-rest advice for billed machines; live mode only.
    @Published private(set) var advice: [AdviceReport] = []
    @Published var earningsSettings = EarningsSettings.load() {
        didSet { earningsSettings.save() }
    }

    private var engine = StatusEngine()
    private var clock = SystemClock()
    private var client: StatusFeedClient?
    private var pollTask: Task<Void, Never>?
    private var isFetching = false
    private var isForeground = true
    /// Set on returning to the foreground until the first fetch finishes. Judging the old samples
    /// before then made every machine gray ("電腦端沒有回應") and raised a false alert after the
    /// screen had been off a few minutes, although all were green a moment later.
    private var awaitingResumeFetch = false

    init() {
        controlToken = ControlSecret.load()
        hasControlToken = controlToken != nil
        demo = DemoPlayer.loadBundled()
        demoNotice = demo?.notice ?? ""
        selectDemo(.confirmedMining)
        if let saved = LiveResume.savedSource() {
            startLive(endpoint: saved.endpoint, pollInterval: saved.pollInterval)
        }
    }

    // MARK: - Demo

    func selectDemo(_ scenario: DemoScenario) {
        stopPolling()
        client = nil
        mode = .demo
        self.scenario = scenario
        advice = []
        cumulative = nil
        guard let demo else {
            snapshots = []
            feedProblem = nil
            demoClock = nil
            market = nil
            demoError = "找不到或無法解碼內建示範資料 demo-running.json（需加入 App 資源，且必須標示為 demo）。"
            return
        }
        do {
            let result = try demo.run(scenario)
            snapshots = result.snapshots
            feedProblem = result.feedProblem
            demoClock = result.clock
            market = result.market
            cumulative = result.cumulative
            demoError = nil
        } catch {
            snapshots = []
            feedProblem = nil
            demoClock = nil
            market = nil
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
        market = nil
        cumulative = nil
        advice = []
        LiveResume.enabled = true
        if isForeground { startPolling() }
    }

    func stopLiveAndReturnToDemo() {
        LiveResume.enabled = false
        attentionAlert = nil
        controlNotice = nil
        selectDemo(scenario)
    }

    func dismissAttentionAlert() {
        attentionAlert = nil
    }

    // MARK: - Control

    /// Empty removes the password.
    func setControlToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        controlToken = trimmed.isEmpty ? nil : trimmed
        hasControlToken = controlToken != nil
        controlTokenPersisted = ControlSecret.save(trimmed)
    }

    /// Only after the user confirmed, only in live mode, only to the configured source.
    func sendControl(_ action: ControlAction, to machineId: String) async {
        guard mode == .live, let endpoint, let token = controlToken, controlInFlight == nil else { return }
        controlInFlight = machineId
        controlNotice = nil
        let result = await ControlClient(endpoint: endpoint).send(machineId: machineId, action: action, token: token)
        controlInFlight = nil
        guard mode == .live, self.endpoint == endpoint else { return }
        switch result {
        case .success(let message): controlNotice = ControlNotice(machineId: machineId, text: message, succeeded: true)
        case .failure(.cancelled): break
        case .failure(let failure):
            controlNotice = ControlNotice(machineId: machineId, text: failure.displayText, succeeded: false)
        }
        refreshNow()
    }

    // MARK: - Earnings

    /// True when anything earnings-related arrived; older sources send none and the UI hides it.
    var hasEarnings: Bool {
        market != nil || snapshots.contains { $0.sample?.earnings != nil }
    }

    func isBilled(_ snapshot: MachineSnapshot) -> Bool {
        earningsSettings.billed[snapshot.machineId] ?? snapshot.sample?.earnings?.electricityBilled ?? false
    }

    func setBilled(_ machineId: String, _ billed: Bool) {
        earningsSettings.billed[machineId] = billed
    }

    func extraWatts(_ machineId: String) -> Double {
        earningsSettings.extraWatts[machineId] ?? EarningsSettings.defaultExtraWatts
    }

    func setExtraWatts(_ machineId: String, _ watts: Double) {
        earningsSettings.extraWatts[machineId] = watts
    }

    /// Demo uses its frozen clock so the shown day matches the demo data.
    func earnings(for snapshot: MachineSnapshot) -> MachineEarnings {
        EarningsCalculator.estimate(
            status: snapshot.sample, market: market, billed: isBilled(snapshot),
            extraWatts: extraWatts(snapshot.machineId), tariff: effectiveTariff,
            day: mode == .demo ? (demoClock?.wall ?? Date()) : Date())
    }

    var earningsTotal: (revenue: Double?, electricity: Double?, net: Double?) {
        EarningsCalculator.total(snapshots.map(earnings(for:)))
    }

    /// The clock the screen should reason about: the frozen demo clock, or now.
    var displayNow: Date { mode == .demo ? (demoClock?.wall ?? Date()) : Date() }

    /// True when the rates in use are the source's published ones.
    var usingSourceRates: Bool { earningsSettings.useSourceTariff && sourceTariff != nil }

    /// Rates from the source when chosen and available, otherwise the user's; the source's days
    /// off apply either way.
    var effectiveTariff: TouTariff {
        var tariff = usingSourceRates ? sourceTariff.map(TouTariff.init(report:)) ?? earningsSettings.tariff
                                      : earningsSettings.tariff
        tariff.offPeakDates = Set(sourceTariff?.offPeakDates ?? [])
        return tariff
    }

    /// Current tariff period and the hourly cost of the machines that pay for electricity.
    var currentElectricity: (period: String, rate: Double, perHour: Double?) {
        let period = effectiveTariff.period(at: displayNow)
        let watts = snapshots.filter(isBilled).compactMap { earnings(for: $0).powerW }
        return (period.name, period.rate, watts.isEmpty ? nil : watts.reduce(0, +) / 1000 * period.rate)
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
            awaitingResumeFetch = true
            startPolling()  // fetches first; judging waits for that answer
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
        // A fetch from a just-cancelled loop may still be finishing: wait for it, or this loop's
        // first fetch is skipped and the screen stays empty for a whole interval. Happened at
        // launch, when the reconnect's fetch was cancelled by the first foreground event.
        while isFetching, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
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
        // A cancelled fetch is not the fresh answer that judging waits for.
        if result != .failure(.cancelled) { awaitingResumeFetch = false }
        switch result {
        case .success(let feed):
            lastSuccessAt = Date()
            lastFailure = nil
            sourceSentDemoData = feed.isDemo
            market = feed.market
            cumulative = feed.cumulative
            advice = feed.advice ?? []
            if let tariff = feed.tariff, tariff != sourceTariff {
                sourceTariff = tariff
                SourceTariffStore.save(tariff)
            }
        case .failure(.cancelled):
            break
        case .failure(let failure):
            lastFailure = failure
        }
        reevaluate()
    }

    private func reevaluate() {
        guard mode == .live, !awaitingResumeFetch else { return }
        let previous = snapshots
        // The source's own judgment wins while fresh; see applyingPublisherAssessment.
        snapshots = engine.snapshots(at: clock.reading()).map { $0.applyingPublisherAssessment() }
        feedProblem = engine.feedProblem
        let degraded = StatusAlerts.newlyDegraded(from: previous, to: snapshots)
        if !degraded.isEmpty {
            attentionAlert = StatusAlerts.describe(degraded).joined(separator: "\n")
        }
    }
}
