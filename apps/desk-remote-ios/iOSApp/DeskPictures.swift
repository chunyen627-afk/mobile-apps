import DeskRemoteCore
import SwiftUI
import UIKit

/// Pictures of conversations, fetched from the PC once and kept in memory (about 60 MB), so
/// scrolling back and forth does not ask again. Thumbnails are drawn from the same image.
@MainActor
final class DeskImageCache {
    static let shared = DeskImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]

    init() {
        cache.totalCostLimit = 60 * 1024 * 1024
    }

    /// The picture, from memory or by `fetch`; nil when the PC no longer has it. One fetch per
    /// picture at a time, however many rows show it.
    func image(pc: UUID, app: DeskApp, session: String, id: String,
               fetch: @escaping @Sendable () async throws -> Data) async -> UIImage? {
        let key = "\(pc.uuidString)/\(app.rawValue)/\(session)/\(id)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = loading[key] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let data = try? await fetch(), let image = UIImage(data: data) else { return nil }
            return image
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }
}

/// Thumbnails of a message's pictures in a row; a tap opens the picture full screen.
struct DeskPictureStrip: View {
    let ids: [String]
    let loadImage: (String) async -> UIImage?
    @State private var shown: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ids, id: \.self) { id in
                    DeskThumbnail(id: id, loadImage: loadImage) { shown = id }
                }
            }
        }
        // As wide as the pictures (two at most), so the bubble hugs them instead of the screen
        // (CI screenshot 10/31: a thumbnail in a bubble the width of the screen).
        .frame(maxWidth: CGFloat(min(ids.count, 2)) * 150 + CGFloat(min(ids.count, 2) - 1) * 6, alignment: .leading)
        .sheet(item: Binding(get: { shown.map(DeskShownPicture.init) }, set: { shown = $0?.id })) { picked in
            DeskPictureViewer(id: picked.id, loadImage: loadImage)
        }
    }
}

private struct DeskShownPicture: Identifiable {
    let id: String
}

struct DeskThumbnail: View {
    let id: String
    let loadImage: (String) async -> UIImage?
    let open: () -> Void
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        Button(action: open) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if missing {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("圖已不在電腦端").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 150, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .accessibilityLabel(image == nil ? (missing ? "圖已不在電腦端" : "圖片載入中") : "圖片，點一下放大")
        .accessibilityIdentifier(image == nil ? "picture-loading" : "picture")
        .task(id: id) {
            image = await loadImage(id)
            missing = image == nil
        }
    }
}

/// One picture filling the screen, pinch to zoom, swipe down (the sheet) to close.
struct DeskPictureViewer: View {
    let id: String
    let loadImage: (String) async -> UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .frame(width: UIScreen.main.bounds.width * scale, height: UIScreen.main.bounds.height * 0.8 * scale)
                    }
                    .gesture(MagnificationGesture()
                        .onChanged { value in scale = min(5, max(1, lastScale * value)) }
                        .onEnded { _ in lastScale = scale })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; lastScale = scale } }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("關閉") { dismiss() } }
                if let image {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("圖片", image: Image(uiImage: image)))
                    }
                }
            }
            .accessibilityIdentifier("picture-viewer")
            .task { image = await loadImage(id) }
        }
    }
}

/// Several tool calls in a row, folded into one line as the desktop shows them: "已執行 3 個指令、
/// 已讀取 2 個檔案"; opened, each call is its own row.
struct DeskToolGroupRow<Inner: View>: View {
    let row: TranscriptRow
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder let inner: () -> Inner

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                    Image(systemName: row.hasError ? "xmark.octagon" : "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(row.hasError ? Color.red : Color.secondary)
                    Text(Self.summary(row.toolCounts)).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-group")
            if expanded {
                VStack(alignment: .leading, spacing: 6) { inner() }
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }

    /// The desktop's wording for the usual tools, "N 次 <tool>" for the rest.
    static func summary(_ counts: [(tool: String, count: Int)]) -> String {
        counts.map { item -> String in
            switch item.tool {
            case "Bash", "指令", "PowerShell": return "已執行 \(item.count) 個指令"
            case "Read": return "已讀取 \(item.count) 個檔案"
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return "已編輯 \(item.count) 個檔案"
            case "Grep", "Glob": return "已搜尋 \(item.count) 次"
            case "WebSearch", "WebFetch": return "已上網 \(item.count) 次"
            default: return "\(item.tool) ×\(item.count)"
            }
        }.joined(separator: "、")
    }
}
