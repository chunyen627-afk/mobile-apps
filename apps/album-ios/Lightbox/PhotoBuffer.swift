import ImageIO
import UIKit

/// At most the current and next decoded photo; pending prefetch is shared with display.
@MainActor
final class PhotoBuffer {
    typealias Load = @Sendable (AlbumEntry) async throws -> UIImage
    private let load: Load
    private var images: [String: UIImage] = [:]
    private var pending: [String: (id: UUID, task: Task<UIImage, Error>)] = [:]
    private var allowed = Set<String>()

    init(load: @escaping Load) { self.load = load }

    func retain(_ entries: [AlbumEntry]) {
        allowed = Set(entries.filter { $0.kind == .photo }.map(\.path))
        images = images.filter { allowed.contains($0.key) }
        for path in Array(pending.keys) where !allowed.contains(path) {
            pending.removeValue(forKey: path)?.task.cancel()
        }
    }

    func image(for entry: AlbumEntry) async throws -> UIImage {
        try Task.checkCancellation()
        if let image = images[entry.path] { return image }
        let job: (id: UUID, task: Task<UIImage, Error>)
        if let existing = pending[entry.path] { job = existing }
        else {
            job = (UUID(), Task { [load] in try await load(entry) })
            pending[entry.path] = job
        }
        do {
            let image = try await job.task.value
            if pending[entry.path]?.id == job.id {
                pending.removeValue(forKey: entry.path)
                if allowed.contains(entry.path) { images[entry.path] = image }
            }
            try Task.checkCancellation()
            return image
        } catch {
            if pending[entry.path]?.id == job.id { pending.removeValue(forKey: entry.path) }
            throw error
        }
    }

    func clear() { retain([]) }

    static func decode(_ entry: AlbumEntry, service: SMBService) async throws -> UIImage {
        let limit: Int64 = 80 * 1024 * 1024
        guard entry.size <= limit else { throw AlbumError.message("照片超過 80 MB，請按下一個略過。") }
        let data = try await service.read(entry.path, range: 0..<(limit + 1))
        try Task.checkCancellation()
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
        guard let decoded else { throw AlbumError.message("照片格式不支援或檔案損壞，請按下一個略過。") }
        return decoded
    }
}
