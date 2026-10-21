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
    let entries: [AlbumEntry]
    private let service: SMBService
    private let interval: Double
    private var mediaTask: Task<Void, Never>?
    private var slideTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?
    private var loader: SMBResourceLoader?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var sessionID = UUID()
    private var previousIdleSetting = false
    private var didStart = false
    var entry: AlbumEntry { entries[index] }

    init(entries: [AlbumEntry], service: SMBService, interval: Double) {
        self.entries = entries
        self.service = service
        self.interval = interval
    }

    func start() {
        guard !didStart, !entries.isEmpty else { return }
        didStart = true
        previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        show(0)
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        sessionID = UUID()
        clearMedia()
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
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        loader?.stop(); loader = nil
        image = nil
    }

    func show(_ target: Int) {
        guard didStart, !entries.isEmpty else { return }
        clearMedia()
        index = (target % entries.count + entries.count) % entries.count
        let ticket = UUID()
        sessionID = ticket
        loading = true
        message = nil
        let item = entry
        revealControls()
        if item.kind == .video {
            guard item.size > 0 else { fail("影片大小無效，請重新掃描。", ticket: ticket); return }
            let resource = SMBResourceLoader(service: service, entry: item)
            loader = resource
            let playerItem = AVPlayerItem(asset: resource.asset())
            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.automaticallyWaitsToMinimizeStalling = true
            player = avPlayer
            statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] current, _ in
                Task { @MainActor in
                    guard let self, self.sessionID == ticket else { return }
                    if current.status == .readyToPlay {
                        self.loading = false
                        if !self.paused { self.player?.play() }
                    } else if current.status == .failed {
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
                    if !self.paused { self.next() }
                }
            }
            if !paused { avPlayer.play() }
        } else {
            mediaTask = Task { [weak self, service] in
                do {
                    let limit: Int64 = 80 * 1024 * 1024
                    guard item.size <= limit else { throw AlbumError.message("照片超過 80 MB，第一版請先縮小檔案。") }
                    let data = try await service.read(item.path, range: 0..<(limit + 1))
                    guard data.count <= limit else { throw AlbumError.message("照片超過 80 MB，請按下一個略過。") }
                    let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 2800,
                                kCGImageSourceShouldCacheImmediately: true
                              ] as CFDictionary) else { return nil }
                        return UIImage(cgImage: cgImage)
                    }.value
                    try Task.checkCancellation()
                    guard let self, self.sessionID == ticket else { return }
                    guard let decoded else { throw AlbumError.message("照片格式不支援或檔案損壞，請按下一個略過。") }
                    self.image = decoded
                    self.loading = false
                    self.scheduleSlide()
                } catch is CancellationError { }
                catch { self?.fail(error.localizedDescription, ticket: ticket) }
            }
        }
    }

    private func fail(_ text: String, ticket: UUID) {
        guard ticket == sessionID else { return }
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
        guard !paused, !loading, message == nil, entry.kind == .photo else { return }
        slideTask = Task { [weak self, interval] in
            do { try await Task.sleep(for: .seconds(interval)); try Task.checkCancellation(); self?.next() }
            catch { }
        }
    }

    func revealControls() {
        controlsVisible = true
        controlsTask?.cancel()
        // Keep controls visible for video so native seek/volume controls stay reachable.
        guard !paused, message == nil, entry.kind == .photo else { return }
        controlsTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)); try Task.checkCancellation(); self?.controlsVisible = false }
            catch { }
        }
    }

    func suspend() { paused = true; slideTask?.cancel(); player?.pause(); controlsVisible = true }
}
