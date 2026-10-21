import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Serves AVPlayer's byte ranges directly from SMB, including seeks near the end
/// of a movie. All AVAssetResourceLoadingRequest interaction uses one queue.
final class SMBResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let service: SMBService
    private let entry: AlbumEntry
    let queue = DispatchQueue(label: "Lightbox.media.resource")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(service: SMBService, entry: AlbumEntry) { self.service = service; self.entry = entry }

    func asset() -> AVURLAsset {
        var parts = URLComponents()
        parts.scheme = "lightbox-smb"
        parts.host = "media"
        parts.path = "/" + entry.name
        let asset = AVURLAsset(url: parts.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped else { request.finishLoading(with: URLError(.cancelled)); return true }
        if let info = request.contentInformationRequest {
            info.contentType = UTType(filenameExtension: (entry.name as NSString).pathExtension)?.identifier ?? UTType.movie.identifier
            info.contentLength = entry.size
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else { request.finishLoading(); return true }
        let start = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        let requestedEnd = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
        let end = dataRequest.requestsAllDataToEndOfResource || requestedEnd.overflow ? entry.size : min(entry.size, requestedEnd.partialValue)
        let id = ObjectIdentifier(request)
        pump(request, id: id, offset: start, end: end)
        return true
    }

    private func pump(_ request: AVAssetResourceLoadingRequest, id: ObjectIdentifier, offset: Int64, end: Int64) {
        guard !stopped, !request.isCancelled, !request.isFinished else { tasks.removeValue(forKey: id); return }
        guard offset < end else { request.finishLoading(); tasks.removeValue(forKey: id); return }
        let upper = min(end, offset + 512 * 1024)
        tasks[id] = Task { [weak self, service, entry] in
            do {
                let data = try await service.read(entry.path, range: offset..<upper)
                try Task.checkCancellation()
                self?.queue.async { [weak self] in
                    guard let self, !self.stopped, !request.isCancelled, !request.isFinished else { return }
                    guard !data.isEmpty else {
                        request.finishLoading(with: AlbumError.message("影片讀取提前結束，請重新連線。"))
                        self.tasks.removeValue(forKey: id)
                        return
                    }
                    request.dataRequest?.respond(with: data)
                    self.pump(request, id: id, offset: offset + Int64(data.count), end: end)
                }
            } catch {
                self?.queue.async { [weak self] in
                    if !request.isCancelled && !request.isFinished { request.finishLoading(with: error) }
                    self?.tasks.removeValue(forKey: id)
                }
            }
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }
}
