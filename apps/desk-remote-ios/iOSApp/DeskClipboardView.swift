import DeskRemoteCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The shared clipboard (helper 0.5.40). Both PCs keep one folder the cloud drive syncs
/// (G:\我的雲端硬碟\剪貼簿): what is copied on either PC lands there and the other PC takes it
/// into its clipboard. The phone reads the folder through whichever PC answers, a tap copies
/// an item to this phone, and the paste button sends the phone's clipboard to every PC that
/// answers: the first stores it in the folder, the others only take it into their clipboard.
@MainActor
final class DeskClipboardModel: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    /// The PC whose helper answered the list; pictures and long texts are read from it.
    @Published private(set) var via: UUID?
    @Published private(set) var failure: String?
    /// How the last send went ("已送到 辦公室、家裡").
    @Published var note: String?
    @Published private(set) var sending = false
    /// The item just copied to this phone (a check mark for two seconds).
    @Published private(set) var copied: String?
    private(set) var unreachable = false
    let store: DeskStore

    init(store: DeskStore) {
        self.store = store
    }

    func refresh() async {
        var lastFailure: String?
        for pc in store.pcs {
            guard let client = store.client(pc.id) else { continue }
            do {
                let list = try await client.clipboard()
                items = list.items
                via = pc.id
                failure = nil
                unreachable = false
                return
            } catch {
                if let text = DeskNetwork.shared.failureText(error, short: true) {
                    lastFailure = "\(pc.name)：\(text)"
                }
            }
        }
        if store.pcs.isEmpty {
            failure = "還沒有電腦"
        } else if let lastFailure {
            failure = lastFailure
            unreachable = true
        }
    }

    /// The phone's clipboard, as the paste button hands it over: a picture first, else text.
    func paste(_ providers: [NSItemProvider]) async {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let image = await provider.deskImage(), let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9) {
                await send(image: data)
                return
            }
        }
        for provider in providers {
            if let text = await provider.deskString(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await send(text: text)
                return
            }
        }
        note = "手機剪貼簿裡沒有文字或圖片"
    }

    func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await send { client, store in try await client.sendClipboard(text: text, store: store) }
    }

    /// A picture, made small enough to send (long side 2048 px, JPEG) like a photo for a message.
    func send(image: Data) async {
        guard let prepared = DeskPhoto.prepare(image) else {
            note = "這張圖片讀不出來"
            return
        }
        await send { client, store in try await client.sendClipboard(image: prepared, store: store) }
    }

    private func send(_ operation: (HelperClient, Bool) async throws -> ClipboardItem?) async {
        sending = true
        defer { sending = false }
        note = "送出中…"
        var stored = false
        var reached: [String] = []
        var failed: [String] = []
        for pc in store.pcs {
            guard let client = store.client(pc.id) else { continue }
            do {
                _ = try await operation(client, !stored)
                stored = true
                reached.append(pc.name)
            } catch {
                let text = DeskNetwork.shared.failureText(error, short: true) ?? "連不到"
                failed.append("\(pc.name)（\(text)）")
            }
        }
        if reached.isEmpty {
            note = "沒送出：" + (failed.isEmpty ? "還沒有電腦" : failed.joined(separator: "、"))
        } else {
            note = "已送到 " + reached.joined(separator: "、") + (failed.isEmpty ? "" : "；" + failed.joined(separator: "、"))
        }
        await refresh()
    }

    /// Puts the item on this phone's clipboard (a long text and a picture are fetched first).
    func copyToPhone(_ item: ClipboardItem) async {
        let client = via.flatMap { store.client($0) }
        // The simulator's pasteboard is synced with the Mac's; on a headless CI runner that sync
        // never answers and the app hangs (both CI runs of 11/9 hit their time limit), so the UI
        // tests check the row's check mark and leave the system pasteboard alone.
        if item.isImage {
            guard let client, let data = try? await client.clipboardImage(item.id), let image = UIImage(data: data) else {
                note = "這張圖讀不到"
                return
            }
            if !store.uiTest { UIPasteboard.general.image = image }
        } else {
            var text = item.text ?? ""
            if item.truncated == true, let client, let whole = try? await client.clipboardText(item.id) {
                text = whole
            }
            if !store.uiTest { UIPasteboard.general.string = text }
        }
        copied = item.id
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if copied == item.id { copied = nil }
    }

    /// Asks one PC to take a stored item into its clipboard.
    func apply(_ item: ClipboardItem, to pcID: UUID) async {
        guard let pc = store.pc(pcID), let client = store.client(pcID) else { return }
        do {
            try await client.applyClipboard(item.id)
            note = "已放進「\(pc.name)」的剪貼簿"
        } catch {
            note = "「\(pc.name)」沒收到：\(DeskNetwork.shared.failureText(error, short: true) ?? "連不到")"
        }
    }

    func loadImage(_ id: String) async -> UIImage? {
        guard let via, let client = store.client(via) else { return nil }
        return await DeskImageCache.shared.image(key: "clipboard/\(id)") { try await client.clipboardImage(id) }
    }

    /// The picture as stored (not the thumbnail-sized copy), for the viewer and its share sheet.
    func loadFullImage(_ id: String) async -> UIImage? {
        guard let via, let client = store.client(via) else { return nil }
        return await DeskImageCache.shared.image(key: "clipboard-full/\(id)") { try await client.clipboardImage(id, small: false) }
    }

    /// The web address an item is, when its whole text is one (a tap opens it instead of copying).
    static func link(in item: ClipboardItem) -> URL? {
        guard !item.isImage, item.truncated != true, let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: { $0.isWhitespace }),
              text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://"),
              let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}

private struct ClipboardShownPicture: Identifiable {
    let id: String
}

extension NSItemProvider {
    func deskImage() async -> UIImage? {
        guard canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    func deskString() async -> String? {
        guard canLoadObject(ofClass: NSString.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map(String.init))
            }
        }
    }
}

struct DeskClipboardView: View {
    @ObservedObject var store: DeskStore
    @StateObject private var model: DeskClipboardModel
    @State private var draft = ""
    @State private var shownPicture: ClipboardShownPicture?
    @Environment(\.openURL) private var openURL

    init(store: DeskStore) {
        self.store = store
        _model = StateObject(wrappedValue: DeskClipboardModel(store: store))
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .bottom) {
                    TextField("輸入文字送到電腦", text: $draft, axis: .vertical)
                        .lineLimit(1 ... 5)
                        .accessibilityIdentifier("clipboard-text")
                    Button {
                        let text = draft
                        draft = ""
                        Task { await model.send(text: text) }
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .disabled(model.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("送出")
                    .accessibilityIdentifier("clipboard-send")
                }
                // The system's paste button: it reads the phone's clipboard without the paste
                // prompt, and is greyed out while there is no text or picture to paste. Not in
                // the UI tests: it asks the pasteboard, which hangs on a headless CI simulator.
                if !store.uiTest {
                    PasteButton(supportedContentTypes: [.image, .plainText]) { providers in
                        Task { await model.paste(providers) }
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.sending)
                    .accessibilityIdentifier("clipboard-paste")
                }
                if let note = model.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipboard-note")
                }
            } footer: {
                Text("「貼上」把手機剪貼簿裡的文字或圖片送到每一台連得到的電腦（直接進它們的剪貼簿，並存進雲端硬碟的共用資料夾）。電腦上複製的東西會出現在下面：按右邊的複製鈕才複製到手機；網址點一下用瀏覽器打開，圖片點一下放大（左上角分享可存到照片）；長按可指定放進哪一台電腦的剪貼簿。")
            }
            if let failure = model.failure {
                DeskNotice(text: failure, tint: .red)
                    .accessibilityIdentifier("clipboard-error")
            }
            Section(model.via.flatMap { store.pc($0)?.name }.map { "紀錄（經 \($0) 讀取）" } ?? "紀錄") {
                if model.items.isEmpty {
                    Text(model.failure == nil ? "還沒有東西" : "讀不到紀錄")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipboard-empty")
                }
                ForEach(model.items) { item in
                    DeskClipboardRow(item: item, copied: model.copied == item.id, loadImage: model.loadImage, open: {
                        if item.isImage {
                            shownPicture = ClipboardShownPicture(id: item.id)
                        } else if let url = DeskClipboardModel.link(in: item) {
                            openURL(url)
                        }
                    }, copy: {
                        Task { await model.copyToPhone(item) }
                    })
                    .contextMenu {
                        ForEach(store.pcs) { pc in
                            Button {
                                Task { await model.apply(item, to: pc.id) }
                            } label: {
                                Label("放進「\(pc.name)」的剪貼簿", systemImage: "desktopcomputer")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("剪貼簿")
        .sheet(item: $shownPicture) { picked in
            DeskPictureViewer(id: picked.id, loadImage: model.loadFullImage)
        }
        .deskForegroundLoop(every: 5, failing: { model.unreachable }) { await model.refresh() }
        .refreshable { await model.refresh() }
    }
}

/// One item: the text (or a thumbnail), who copied it and when. Only the copy button at the right
/// copies it to this phone (asked 11/9); a tap on a picture opens it full size (the viewer's share
/// sheet saves it to Photos), a tap on a web address opens it in the browser, other text does
/// nothing on a tap.
struct DeskClipboardRow: View {
    let item: ClipboardItem
    let copied: Bool
    let loadImage: (String) async -> UIImage?
    let open: () -> Void
    let copy: () -> Void

    private var link: URL? { DeskClipboardModel.link(in: item) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if item.isImage || link != nil {
                Button(action: open) { content }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(item.isImage ? "放大" : "用瀏覽器打開")
                    .accessibilityIdentifier("clipboard-row-\(item.id)")
            } else {
                content
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("clipboard-row-\(item.id)")
            }
            Spacer(minLength: 4)
            // Two buttons in one list row: borderless, so a tap on either does not fire the other.
            Button(action: copy) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "已複製到手機" : "複製到手機")
            .accessibilityIdentifier("clipboard-copy-\(item.id)")
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 10) {
            if item.isImage {
                DeskClipboardThumbnail(id: item.id, loadImage: loadImage)
            }
            VStack(alignment: .leading, spacing: 3) {
                if item.isImage {
                    Text("圖片・\(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))")
                } else {
                    Text(item.text ?? "")
                        .lineLimit(4)
                        .foregroundStyle(link == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                    if item.truncated == true {
                        Text("長文字，按複製鈕會複製全部")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text([item.source, DeskText.relative(item.at)].compactMap { $0 }.joined(separator: "・"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A clipboard picture's thumbnail (the item's own tap copies it, so this is not a button).
struct DeskClipboardThumbnail: View {
    let id: String
    let loadImage: (String) async -> UIImage?
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if missing {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: id) {
            image = await loadImage(id)
            missing = image == nil
        }
    }
}
