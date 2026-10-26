import DeskRemoteCore
import SwiftUI
import UIKit

/// One conversation, read live: the first page, then long-polls of up to 25 s while the app is
/// in the foreground. Tool calls are folded; a permission question shows as a card with
/// 允許一次／拒絕. Messages typed here are pasted into the desktop app by the PC's helper and
/// stay as pending bubbles until the transcript itself has them.
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
    @State private var draft = ""
    @State private var pending: [DeskPending] = []
    @State private var confirm: DeskConfirm?
    @State private var promptBusy: String?
    @State private var openState: String?
    /// A question was seen here, so the list's "needs action" is no longer news.
    @State private var sawPrompt = false
    @FocusState private var inputFocused: Bool

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
                    ForEach(pending) { item in
                        DeskPendingBubble(item: item, retry: { Task { await send(item, force: false) } },
                                          remove: { pending.removeAll { $0.id == item.id } })
                            .id(item.id.uuidString)
                    }
                    if let prompt = log.prompt {
                        DeskPromptCard(app: app, prompt: prompt, busy: promptBusy,
                                       answer: { allow in Task { await answer(prompt, allow: allow, force: false) } })
                            .id("prompt")
                    } else if session.status == "needs-action" && log.loaded && !sawPrompt {
                        DeskOpenOnPC(state: openState) { Task { await openOnPC(force: false) } }
                    }
                    if log.prompt == nil, let working = DeskText.working(app, status: log.status) {
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
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: log.rows.last?.id) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: pending.count) {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DeskInputBar(text: $draft, focused: $inputFocused) { submitDraft() }
        }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { item in
            Button(item.confirmLabel) { Task { await item.run() } }
            Button("取消", role: .cancel) { item.cancel() }
        } message: { item in
            Text(item.message)
        }
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

    // MARK: - Reading

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
                if log.prompt == nil { promptBusy = nil } else { sawPrompt = true }
                pending.removeAll { $0.mark != nil && log.hasUserText($0.text, after: $0.mark ?? 0) }
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

    // MARK: - Sending

    private func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let item = DeskPending(text: text, mark: log.events.last?.seq ?? 0)
        pending.append(item)
        Task { await send(item, force: false) }
    }

    private func setPending(_ id: UUID, _ change: (inout DeskPending) -> Void) {
        if let index = pending.firstIndex(where: { $0.id == id }) { change(&pending[index]) }
    }

    private func send(_ item: DeskPending, force: Bool) async {
        guard let client = store.client(pcID) else { return }
        setPending(item.id) { $0.status = "送出中…"; $0.failed = false }
        do {
            let start = try await client.send(app, session: session.id, text: item.text,
                                              clientMsgId: item.id.uuidString, force: force)
            setPending(item.id) { $0.status = start.message }
            let end = try await client.follow(start) { status in setPending(item.id) { $0.status = status.message } }
            setPending(item.id) {
                $0.status = end.message
                $0.failed = end.state == "failed"
                if !end.finished { $0.status = "電腦端還在處理" }
            }
        } catch HelperFailure.busyUser(let seconds) {
            setPending(item.id) { $0.status = "等你確認"; $0.failed = false }
            confirm = DeskConfirm(
                title: "電腦有人在用",
                message: "\(seconds.map { "\($0) 秒前" } ?? "剛剛")有人操作過這台電腦。送出會把視窗切到前面並貼上文字，可能打斷正在用電腦的人。",
                confirmLabel: "仍要送出",
                run: { await send(item, force: true) },
                cancel: { setPending(item.id) { $0.status = "已取消，沒有送出"; $0.failed = true } })
        } catch let error as HelperFailure {
            setPending(item.id) { $0.status = "沒有送出：\(DeskText.failure(error))"; $0.failed = true }
        } catch {
            setPending(item.id) { $0.status = "沒有送出：\(DeskText.failure(.unreachable))"; $0.failed = true }
        }
    }

    // MARK: - Permission and opening on the PC

    private func answer(_ prompt: PermissionPrompt, allow: Bool, force: Bool) async {
        guard let client = store.client(pcID) else { return }
        promptBusy = allow ? "正在按「允許一次」…" : "正在按「拒絕」…"
        do {
            let start = try await client.answer(app, session: session.id, promptId: prompt.promptId, allow: allow, force: force)
            let end = try await client.follow(start, timeout: 40)
            promptBusy = end.state == "failed" ? "沒有成功：\(end.message)" : "\(end.message)，等待電腦更新…"
        } catch HelperFailure.busyUser(let seconds) {
            promptBusy = nil
            confirm = DeskConfirm(
                title: "電腦有人在用",
                message: "\(seconds.map { "\($0) 秒前" } ?? "剛剛")有人操作過這台電腦。Claude 的「允許一次」要移動滑鼠點選單。",
                confirmLabel: "仍要按",
                run: { await answer(prompt, allow: allow, force: true) },
                cancel: {})
        } catch let error as HelperFailure {
            promptBusy = "沒有成功：\(DeskText.failure(error))"
        } catch {
            promptBusy = "沒有成功：\(DeskText.failure(.unreachable))"
        }
    }

    private func openOnPC(force: Bool) async {
        guard let client = store.client(pcID) else { return }
        openState = "正在電腦上打開…"
        do {
            let end = try await client.follow(try await client.openOnPC(app, session: session.id, force: force), timeout: 30)
            openState = end.state == "failed" ? "沒有成功：\(end.message)" : "已在電腦上打開，詢問會出現在這裡"
        } catch HelperFailure.busyUser(let seconds) {
            openState = nil
            confirm = DeskConfirm(
                title: "電腦有人在用",
                message: "\(seconds.map { "\($0) 秒前" } ?? "剛剛")有人操作過這台電腦。打開會切換電腦畫面上的對話。",
                confirmLabel: "仍要打開",
                run: { await openOnPC(force: true) },
                cancel: {})
        } catch let error as HelperFailure {
            openState = "沒有成功：\(DeskText.failure(error))"
        } catch {
            openState = "沒有成功：\(DeskText.failure(.unreachable))"
        }
    }
}

/// A message typed on the phone that the transcript does not show yet.
struct DeskPending: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// The newest event seq when it was sent; the transcript must show it after this.
    let mark: Int?
    var status = "排隊中"
    var failed = false
}

/// One "are you sure" question with its two outcomes.
struct DeskConfirm: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let run: @MainActor () async -> Void
    let cancel: @MainActor () -> Void
}

struct DeskPendingBubble: View {
    let item: DeskPending
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(item.failed ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35),
                                                                             style: StrokeStyle(lineWidth: 1, dash: [4])))
                HStack(spacing: 10) {
                    Text(item.status)
                        .font(.caption)
                        .foregroundStyle(item.failed ? Color.red : Color.secondary)
                        .accessibilityIdentifier("pending-status")
                    if item.failed {
                        Button("重試", action: retry).font(.caption)
                        Button("移除", action: remove).font(.caption)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-bubble")
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
                    // Long output scrolls inside a box instead of filling the whole chat.
                    ScrollView {
                        Text(fullText ?? (result.text.isEmpty ? "（沒有輸出）" : result.text))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("tool-output")
                    }
                    .frame(maxHeight: 280)
                    .fixedSize(horizontal: false, vertical: (fullText ?? result.text).count < 600)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
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

/// The question the desktop app is asking now, answered from here: allow once or deny only.
struct DeskPromptCard: View {
    let app: DeskApp
    let prompt: PermissionPrompt
    let busy: String?
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(app.displayName) 正在詢問權限", systemImage: "hand.raised.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            Text(prompt.text).font(.callout).textSelection(.enabled)
                .accessibilityIdentifier("prompt-text")
            if let busy {
                Text(busy).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("prompt-busy")
            } else {
                HStack(spacing: 12) {
                    Button { answer(true) } label: { Text("允許一次").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("prompt-allow")
                    Button(role: .destructive) { answer(false) } label: { Text("拒絕").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("prompt-deny")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("prompt-card")
    }
}

/// A conversation waiting for someone, not open on the PC: its question only shows once it is.
struct DeskOpenOnPC: View {
    let state: String?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("這個對話在等待處理，但電腦上目前開著別的對話，所以看不到它的詢問。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let state {
                Text(state).font(.caption).foregroundStyle(.secondary)
            } else {
                Button("在電腦上打開這個對話", action: open)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("open-on-pc")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The native input bar: multi-line, the iOS keyboard and dictation; sends on the button.
struct DeskInputBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("輸入訊息", text: $text, axis: .vertical)
                .lineLimit(1 ... 6)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .accessibilityIdentifier("chat-input")
            Button(action: send) {
                Image(systemName: "paperplane.fill").font(.title3)
            }
            .disabled(empty)
            .accessibilityLabel("送出")
            .accessibilityIdentifier("chat-send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
