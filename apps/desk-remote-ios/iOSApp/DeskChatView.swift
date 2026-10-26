import DeskRemoteCore
import SwiftUI
import UIKit

/// One conversation, read live: the first page, then long-polls of up to 25 s while the app is
/// in the foreground. Tool calls are folded; a permission question shows as a card.
/// This version is read-only: the input bar is shown but disabled.
struct DeskChatView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    let app: DeskApp
    let session: SessionSummary
    @Environment(\.scenePhase) private var scenePhase
    @State private var log = TranscriptLog()
    @State private var failure: String?
    @State private var expanded: Set<String> = []
    @State private var fullTexts: [String: String] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if log.earlier {
                        Text("更早的內容沒有載入（電腦端只送最近的部分）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    if !log.loaded && failure == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(log.rows) { row in
                        rowView(row).id(row.id)
                    }
                    if let prompt = log.prompt {
                        DeskPromptCard(app: app, prompt: prompt).id("prompt")
                    }
                    if let working = DeskText.working(app, status: log.status) {
                        Label(working, systemImage: "ellipsis.bubble")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat-working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: log.rows.last?.id) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: log.prompt) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let failure {
                DeskNotice(text: failure, tint: .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.systemBackground))
                    .accessibilityIdentifier("chat-error")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { DeskInputBar() }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase == .active) { await follow() }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow) -> some View {
        switch row {
        case .message(let event):
            DeskBubble(event: event, app: app)
        case .status(let event):
            Text(event.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .tool(let call, let result):
            DeskToolRow(call: call, result: result, expanded: expanded.contains(row.id),
                        fullText: result?.itemId.flatMap { fullTexts[$0] },
                        toggle: { toggle(row.id) },
                        loadFull: { itemId in Task { await loadItem(itemId) } })
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Reads until the view goes away or the app leaves the foreground.
    private func follow() async {
        guard scenePhase == .active, let client = store.client(pcID) else {
            if store.client(pcID) == nil { failure = "沒有連線密碼" }
            return
        }
        var wait = 0
        while !Task.isCancelled {
            do {
                let page = try await client.events(app, session: session.id, after: log.cursor, epoch: log.epoch,
                                                   knownPrompt: log.prompt?.promptId, wait: wait)
                log.apply(page)
                failure = nil
                wait = 25
            } catch let error as HelperFailure {
                if error == .cancelled || Task.isCancelled { return }
                failure = DeskText.failure(error)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                if Task.isCancelled { return }
                failure = DeskText.failure(.unreachable)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func loadItem(_ itemId: String) async {
        guard let client = store.client(pcID) else { return }
        do {
            fullTexts[itemId] = try await client.item(app, session: session.id, item: itemId)
        } catch let error as HelperFailure {
            fullTexts[itemId] = "（\(DeskText.failure(error))）"
        } catch {
            fullTexts[itemId] = "（\(DeskText.failure(.unreachable))）"
        }
    }
}

/// A user message (right) or a reply (left), with inline Markdown and fenced code blocks.
struct DeskBubble: View {
    let event: TranscriptEvent
    let app: DeskApp

    private var mine: Bool { event.kind == "user" }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(DeskText.segments(event.text).enumerated()), id: \.offset) { _, segment in
                    if segment.code {
                        Text(segment.text)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(Self.markdown(segment.text))
                    }
                }
                if event.truncated == true {
                    Text("（內容太長，只顯示前段）").font(.caption).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .background(mine ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(mine ? "bubble-user" : "bubble-reply")
            if !mine { Spacer(minLength: 24) }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A tool call folded into one line; tapping shows the call and its output.
struct DeskToolRow: View {
    let call: TranscriptEvent?
    let result: TranscriptEvent?
    let expanded: Bool
    let fullText: String?
    let toggle: () -> Void
    let loadFull: (String) -> Void

    private var tool: String { call?.tool ?? result?.tool ?? "工具" }
    private var summary: String {
        (call?.text ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "（輸出）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                    Image(systemName: result?.isError == true ? "xmark.octagon" : "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(result?.isError == true ? Color.red : Color.secondary)
                    Text(tool).font(.caption.bold())
                    Text(summary).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-\(tool)")
            if expanded {
                if let call, !call.text.isEmpty {
                    Text(call.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let result {
                    Text(fullText ?? (result.text.isEmpty ? "（沒有輸出）" : result.text))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("tool-output")
                    if result.truncated == true, fullText == nil, let itemId = result.itemId {
                        Button("載入完整輸出") { loadFull(itemId) }
                            .font(.caption)
                            .accessibilityIdentifier("tool-load-full")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The question the desktop app is asking now. Answering from the phone comes in the next version.
struct DeskPromptCard: View {
    let app: DeskApp
    let prompt: PermissionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(app.displayName) 正在詢問權限", systemImage: "hand.raised.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            Text(prompt.text).font(.callout).textSelection(.enabled)
            Text("這一版只能查看；請先在電腦上按「允許一次」或「拒絕」。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("prompt-card")
    }
}

/// The native input bar. Disabled in this read-only version.
struct DeskInputBar: View {
    var body: some View {
        HStack(spacing: 8) {
            TextField("下一版才能從手機送出", text: .constant(""), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            Image(systemName: "paperplane.fill")
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("input-bar")
    }
}
