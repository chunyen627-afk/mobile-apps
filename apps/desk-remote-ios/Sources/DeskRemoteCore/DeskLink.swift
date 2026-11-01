import Foundation
import UIKit

/// A `deskremote://open?pc=…&app=…&session=…&title=…` link from a notification: which PC (by
/// the name its helper reports, which is also how the phone names it) and, optionally, one of
/// its conversations or its administrator requests.
public struct DeskLink: Equatable, Sendable {
    public let pc: String
    public let app: DeskApp?
    public let session: String?
    public let title: String?
    public let elevate: Bool

    /// nil for anything that is not such a link.
    public init?(_ url: URL) {
        guard url.scheme == "deskremote", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let pc = items.first(where: { $0.name == "pc" })?.value, !pc.isEmpty
        else { return nil }
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.pc = pc
        elevate = value("elevate") == "1"
        if let raw = value("app"), let app = DeskApp(rawValue: raw), let session = value("session") {
            self.app = app
            self.session = session
            title = value("title")
        } else {
            app = nil
            session = nil
            title = nil
        }
    }
}

/// A photo picked on the phone, made small enough to send: at most `maxSide` pixels on its longer
/// side, JPEG; nil when the data is not an image.
public enum DeskPhoto {
    public static func prepare(_ data: Data, maxSide: CGFloat = 2048, quality: CGFloat = 0.75) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
