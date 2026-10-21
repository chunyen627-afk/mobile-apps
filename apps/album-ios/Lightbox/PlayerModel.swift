import AVFoundation
import ImageIO
import SwiftUI
import UIKit

@MainActor
final class PlayerModel: ObservableObject {
    @Published var image: UIImage?
    @Published var player: AVPlayer?
    @Published var index = 0
    @Published var loading = false
    @Published var paused = false
    @Published var message: String?
    @Published var controlsVisible = true
    @Published var videoPosition = 0.0
    @Published var videoDuration = 0.0
    @Published var videoReady = false
    let entries: [AlbumEntry]
    private let service: SMBService
    private let interval: Double
    private var mediaTask: Task<Void, Never>?
    private var slideTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private let photos: PhotoBuffer
    private let controlsDelay: Double
    private let videoAsset: ((AlbumEntry) -> AVAsset?)?
    private var interacting = false
    private var timeObserver: Any?
    private var memoryObserver: NSObjectProtocol?
    private var loader: SMBResourceLoader?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var sessionID = UUID()
    private var previousIdleSetting = false
    private var didStart = false
    var entry: AlbumEntry { entries[index] }

    init(entries: [AlbumEntry], service: SMBService, interval: Double, controlsDelay: Double = 4,
         photoLoad: PhotoBuffer.Load? = nil, videoAsset: ((AlbumEntry) -> AVAsset?)? = nil) {
        self.entries = entries
        self.service = service
        self.interval = interval
        self.controlsDelay = controlsDelay
        self.videoAsset = videoAsset
        self.photos = PhotoBuffer(load: photoLoad ?? { entry in try await PhotoBuffer.decode(entry, service: service) })
    }

    func start() {
        guard !didStart, !entries.isEmpty else { return }
        didStart = true
        DiagnosticStore.shared.record(.playbackStarted, values: ["items": entries.count])
        previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.prefetchTask?.cancel(); self?.photos.clear() }
        }
        show(0)
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        DiagnosticStore.shared.record(.playbackStopped)
        sessionID = UUID()
        clearMedia()
        image = nil
        prefetchTask?.cancel(); prefetchTask = nil
        photos.clear()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
        controlsTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func clearMedia() {
        mediaTask?.cancel(); mediaTask = nil
        slideTask?.cancel(); slideTask = nil
        statusObservation?.invalidate(); statusObservation = nil
        playbackObservation?.invalidate(); playbackObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        loader?.stop(); loader = nil
        videoPosition = 0; videoDuration = 0; videoReady = false
    }

    func show(_ target: Int, userInitiated: Bool = true) {
        guard didStart, !entries.isEmpty else { return }
        clearMedia()
        index = (target % entries.count + entries.count) % entries.count
        let ticket = UUID()
        sessionID = ticket
        loading = true
        message = nil
        let item = entry
        DiagnosticStore.shared.record(item.kind == .video ? .videoSelected : .photoSelected, values: ["index": index, "items": entries.count])
        let upcoming = entries[(index + 1) % entries.count]
        photos.retain([item, upcoming])
        prefetchTask?.cancel()
        if userInitiated { revealControls() }
        if item.kind == .video {
            guard item.size > 0 else { fail("影片大小無效，請重新掃描。", ticket: ticket); return }
            let asset: AVAsset
            if let supplied = videoAsset?(item) { asset = supplied }
            else {
                let resource = SMBResourceLoader(service: service, entry: item)
                loader = resource
                asset = resource.asset()
            }
            let playerItem = AVPlayerItem(asset: asset)
            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.automaticallyWaitsToMinimizeStalling = true
            player = avPlayer
            timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.sessionID == ticket else { return }
                    let duration = self.player?.currentItem?.duration.seconds ?? 0
                    self.videoDuration = duration.isFinite ? max(0, duration) : 0
                    self.videoPosition = time.seconds.isFinite ? max(0, time.seconds) : 0
                }
            }
            statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] current, _ in
                Task { @MainActor in
                    guard let self, self.sessionID == ticket else { return }
                    if current.status == .readyToPlay {
                        self.loading = false
                        if !self.paused { self.player?.play() }
                    } else if current.status == .failed {
                        if let error = current.error { DiagnosticStore.shared.recordError(.videoFailed, error: error) }
                        self.fail("此影片無法播放：可能是編碼不支援或網路中斷。請按下一個略過。", ticket: ticket)
                    }
                }
            }
            playbackObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] current, _ in
                Task { @MainActor in
                    guard let self, self.sessionID == ticket, self.message == nil else { return }
                    self.loading = current.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sessionID == ticket else { return }
                    if !self.paused { self.show(self.index + 1, userInitiated: false) }
                }
            }
            if !paused { avPlayer.play() }
            prefetch(upcoming)
        } else {
            mediaTask = Task { [weak self, photos] in
                do {
                    let decoded = try await photos.image(for: item)
                    try Task.checkCancellation()
                    guard let self, self.sessionID == ticket else { return }
                    self.image = decoded
                    self.loading = false
                    self.scheduleSlide()
                    self.prefetch(upcoming)
                } catch is CancellationError { }
                catch {
                    DiagnosticStore.shared.recordError(.photoFailed, error: error)
                    self?.fail(error.localizedDescription, ticket: ticket)
                }
            }
        }
    }

    private func prefetch(_ item: AlbumEntry) {
        guard item.kind == .photo, entries.count > 1 else { return }
        prefetchTask = Task { [photos] in _ = try? await photos.image(for: item) }
    }

    func videoBecameVisible(_ current: AVPlayer) {
        guard player === current else { return }
        videoReady = true
        image = nil
    }

    func seekVideo(_ seconds: Double) {
        guard seconds.isFinite, videoDuration > 0 else { return }
        DiagnosticStore.shared.record(.videoSeek, values: ["seconds": Int(min(max(0, seconds), videoDuration))])
        player?.seek(to: CMTime(seconds: min(max(0, seconds), videoDuration), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setInteracting(_ active: Bool) {
        interacting = active
        if active { slideTask?.cancel() }
        else { scheduleSlide() }
        revealControls()
    }

    private func fail(_ text: String, ticket: UUID) {
        guard ticket == sessionID else { return }
        DiagnosticStore.shared.record(.playbackFailed, values: ["index": index])
        loading = false; message = text; paused = true; controlsVisible = true
        controlsTask?.cancel()
        player?.pause()
    }

    func next() { show(index + 1) }
    func previous() { show(index - 1) }

    func togglePause() {
        if message != nil { paused = false; show(index); return }
        paused.toggle()
        if paused { slideTask?.cancel(); player?.pause() }
        else if entry.kind == .video { player?.play() }
        else { scheduleSlide() }
        revealControls()
    }

    func scheduleSlide() {
        slideTask?.cancel()
        guard !paused, !loading, !interacting, message == nil, entry.kind == .photo else { return }
        slideTask = Task { [weak self, interval] in
            do { try await Task.sleep(for: .seconds(interval)); try Task.checkCancellation(); guard let self else { return }; self.show(self.index + 1, userInitiated: false) }
            catch { }
        }
    }

    func revealControls() {
        controlsVisible = true
        controlsTask?.cancel()
        guard !paused, !interacting, message == nil else { return }
        controlsTask = Task { [weak self, controlsDelay] in
            do { try await Task.sleep(for: .seconds(controlsDelay)); try Task.checkCancellation(); self?.controlsVisible = false }
            catch { }
        }
    }

    func suspend() { paused = true; slideTask?.cancel(); player?.pause(); revealControls() }
}
