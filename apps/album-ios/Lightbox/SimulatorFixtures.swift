#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import SwiftUI

/// Synthetic media, compiled out of every device Release build. No SMB credentials or photos.
enum SimulatorFixtures {
    static var active: Bool { ProcessInfo.processInfo.environment["LIGHTBOX_UI_TEST"] == "1" }
    static let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-video.mov")
    static let roots = [AlbumEntry(path: "A-Photos", name: "測試照片", kind: .folder, size: 0),
                        AlbumEntry(path: "B-Video", name: "測試影片", kind: .folder, size: 0)]

    static func list(_ path: String) async throws -> [AlbumEntry] {
        try await Task.sleep(for: .milliseconds(150))
        if path == "B-Video" { return [AlbumEntry(path: "B-Video/sample.mov", name: "測試影片.mov", kind: .video, size: 1000)] }
        return (1...3).map { AlbumEntry(path: "A-Photos/\($0).jpg", name: "測試照片 \($0)", kind: .photo, size: 1000) }
    }

    @MainActor static func photo(_ entry: AlbumEntry) async throws -> UIImage {
        try await Task.sleep(for: .milliseconds(700))
        return UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1600)).image { context in
            (entry.path.contains("2.jpg") ? UIColor.systemTeal : UIColor.systemOrange).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1600))
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(14)
            context.cgContext.strokeEllipse(in: CGRect(x: 90, y: 440, width: 720, height: 720))
            (entry.name as NSString).draw(at: CGPoint(x: 160, y: 760), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.white])
        }
    }

    static func prepareVideo() async throws {
        if FileManager.default.fileExists(atPath: videoURL.path) { return }
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AlbumError.message("Cannot create fixture video") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? AlbumError.message("Fixture writer stopped") }
                try await Task.sleep(for: .milliseconds(10))
            }
            var pixel: CVPixelBuffer?
            guard let pool = adapter.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw AlbumError.message("Fixture buffer failed") }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel), let context = CGContext(data: base, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.setFillColor(CGColor(red: 0.05, green: 0.55, blue: 0.7, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.setLineWidth(8)
                context.strokeEllipse(in: CGRect(x: 230, y: 90, width: 180, height: 180))
                context.setFillColor(CGColor(red: 1, green: 0.7, blue: 0, alpha: 1))
                context.fill(CGRect(x: frame * 10, y: 20, width: 40, height: 30))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)) else { throw writer.error ?? AlbumError.message("Fixture frame failed") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AlbumError.message("Fixture encoding failed") }
    }
}

struct SimulatorFixturesView: View {
    @State private var ready = false
    @State private var error: String?
    var body: some View {
        Group {
            if ready { LibraryView() }
            else if let error { Text(error) }
            else { ProgressView("準備模擬器測試素材") }
        }.task {
            do { try await SimulatorFixtures.prepareVideo(); ready = true }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
