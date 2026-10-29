import DeskRemoteCore
import PhotosUI
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
    @ObservedObject private var network = DeskNetwork.shared
    @State private var log = TranscriptLog()
    @State private var failure: String?
    @State private var expanded: Set<String> = []
    @State private var fullTexts: [String: String] = [:]
    @State private var draft = ""
    @State private var pending: [DeskPending] = []
    @State private var confirm: DeskConfirm?
    @State private var promptBusy: String?
    @State private var questionBusy: String?
    @State private var openState: String?
    /// A question was seen here, so the list's "needs action" is no longer news.
    @State private var sawPrompt = false
    @State private var showingMeta = false
    @State private var stopState: String?
    /// Photos picked for the next message, in order, already made small enough to send.
    @State private var photos: [Data] = []
    /// The PC's state, for the windows that popped up on it and how many photos it takes.
    @State private var pcState: HelperState?
    @StateObject private var presser = DeskPopupPresser()
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
                    } else if session.status == "needs-action" && log.loaded && !sawPrompt && log.question == nil {
                        DeskOpenOnPC(state: openState) { Task { await openOnPC(force: false) } }
                    }
                    if let question = log.question {
                        DeskQuestionCard(question: question, busy: questionBusy) { answers in
                            Task { await answerQuestion(question, answers: answers, force: false) }
                        }
                        .id("question-\(question.questionId)")
                    }
                    if log.prompt == nil, log.question == nil, let working = DeskText.working(app, status: log.status) {
                        HStack(spacing: 12) {
                            Label(working, systemImage: "ellipsis.bubble")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("chat-working")
                            // Both apps (Codex's stop button read live 10/27); an older helper answers "not supported".
                            Button(role: .destructive) { Task { await stopTurn(force: false) } } label: {
                                Label("停止", systemImage: "stop.circle")
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                            .disabled(stopState != nil && stopState?.hasPrefix("沒有成功") == false)
                            .accessibilityIdentifier("chat-stop")
                        }
                    }
                    // Stays after the turn ends, so "已停止" is still readable.
                    if let stopState {
                        Text(stopState).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat-stop-state")
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
            .onChange(of: log.question?.questionId) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let line = DeskText.metaLine(log.meta) {
                    DeskMetaBar(line: line) { showingMeta = true }
                }
                if let failure {
                    DeskNotice(text: failure, tint: .red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.systemBackground))
                        .accessibilityIdentifier("chat-error")
                }
                // A window waiting on the PC keeps messages from going through: answer it here.
                if let popups = pcState?.shownPopups, !popups.isEmpty || presser.result != nil {
                    DeskPopupList(popups: popups, presser: presser, compact: true) { popup, button in
                        Task { await presser.press(popup, button, client: store.client(pcID)) { await refreshPC() } }
                    }
                    .padding(8)
                    .background(Color(.systemBackground))
                }
            }
        }
        .deskForegroundLoop(every: 10) { await refreshPC() }
        .sheet(isPresented: $showingMeta) {
            DeskModelSheet(store: store, pcID: pcID, app: app, session: session, meta: log.meta)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let suggestions = log.suggestions, pending.isEmpty, log.question == nil, log.prompt == nil {
                    DeskQuickReplies(suggestions: suggestions) { reply in submit(reply.message) }
                }
                DeskInputBar(text: $draft, photos: $photos, limit: pcState?.photoLimit ?? 1,
                             focused: $inputFocused) { submitDraft() }
            }
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
        // A new network starts over at once instead of waiting out a long-poll on the old one.
        .task(id: [scenePhase == .active ? 1 : 0, network.changes]) { await follow() }
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
                                                   knownPrompt: log.prompt?.promptId,
                                                   knownQuestion: log.question?.questionId, wait: wait)
                let previousQuestion = log.question?.questionId
                log.apply(page)
                if log.prompt == nil { promptBusy = nil } else { sawPrompt = true }
                if log.question?.questionId != previousQuestion { questionBusy = nil }
                pending.removeAll { $0.mark != nil && log.hasUserText($0.text, after: $0.mark ?? 0) }
                failure = nil
                wait = 25
            } catch {
                if Task.isCancelled { return }
                guard let text = DeskNetwork.shared.failureText(error) else { return }
                failure = text
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
        guard !text.isEmpty || !photos.isEmpty else { return }
        draft = ""
        submit(text, photos: photos)
        photos = []
    }

    /// Sends typed text (with the picked photos) or a quick reply's message the same way.
    private func submit(_ text: String, photos: [Data] = []) {
        stopState = nil
        let item = DeskPending(text: text, mark: log.events.last?.seq ?? 0, photos: photos)
        pending.append(item)
        Task { await send(item, force: false) }
    }

    private func stopTurn(force: Bool) async {
        guard let client = store.client(pcID) else { return }
        stopState = "正在電腦上按停止…"
        do {
            let end = try await client.follow(try await client.stop(app, session: session.id, force: force), timeout: 30)
            stopState = end.state == "failed" ? "沒有成功：\(end.message)" : end.message
        } catch let error as HelperFailure {
            stopState = "沒有成功：\(DeskText.failure(error))"
        } catch {
            stopState = "沒有成功：\(DeskText.failure(.unreachable))"
        }
    }

    private func setPending(_ id: UUID, _ change: (inout DeskPending) -> Void) {
        if let index = pending.firstIndex(where: { $0.id == id }) { change(&pending[index]) }
    }

    private func send(_ item: DeskPending, force: Bool) async {
        guard let client = store.client(pcID) else { return }
        setPending(item.id) { $0.status = "送出中…"; $0.failed = false }
        do {
            let start = try await client.send(app, session: session.id, text: item.text,
                                              clientMsgId: item.id.uuidString, images: item.photos, force: force)
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
        if pending.first(where: { $0.id == item.id })?.failed == true { await refreshPC() }
    }

    /// The PC's state: windows that popped up on it, and how many photos one message may carry.
    private func refreshPC() async {
        guard let client = store.client(pcID), let fresh = try? await client.state() else { return }
        pcState = fresh
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

    private func answerQuestion(_ question: OptionQuestion, answers: [QuestionAnswer], force: Bool) async {
        guard let client = store.client(pcID) else { return }
        questionBusy = "正在電腦上選擇…"
        do {
            let start = try await client.answerQuestion(app, session: session.id, questionId: question.questionId,
                                                        answers: answers, force: force)
            let end = try await client.follow(start, timeout: 60)
            questionBusy = end.state == "failed" ? "沒有成功：\(end.message)" : "\(end.message)，等待電腦更新…"
        } catch HelperFailure.busyUser(let seconds) {
            questionBusy = nil
            confirm = DeskConfirm(
                title: "電腦有人在用",
                message: "\(seconds.map { "\($0) 秒前" } ?? "剛剛")有人操作過這台電腦。回答會把視窗切到前面並點選選項。",
                confirmLabel: "仍要回答",
                run: { await answerQuestion(question, answers: answers, force: true) },
                cancel: {})
        } catch let error as HelperFailure {
            questionBusy = "沒有成功：\(DeskText.failure(error))"
        } catch {
            questionBusy = "沒有成功：\(DeskText.failure(.unreachable))"
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
    var photos: [Data] = []
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
                if item.photos.count == 1, let image = UIImage(data: item.photos[0]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 160, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("照片")
                } else if item.photos.count > 1 {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 4), count: min(3, item.photos.count)),
                              alignment: .trailing, spacing: 4) {
                        ForEach(item.photos.indices, id: \.self) { index in
                            if let image = UIImage(data: item.photos[index]) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.photos.count) 張照片")
                    .accessibilityIdentifier("pending-photos")
                }
                Text(item.text.isEmpty ? (item.photos.count > 1 ? "（只有 \(item.photos.count) 張照片）" : "（只有照片）") : item.text)
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
                ForEach(Array(DeskText.blocks(event.text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .code(let code):
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    case .prose(let prose):
                        Text(Self.markdown(prose))
                    case .heading(let level, let heading):
                        Text(Self.markdown(heading))
                            .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                            .padding(.top, 2)
                    case .table(let header, let rows):
                        DeskTable(header: header, rows: rows)
                    case .rule:
                        Divider()
                    }
                }
                if event.truncated == true {
                    Text("（內容太長，只顯示前段）").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(mine ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            // Long press: copy all, or open the text where any part can be selected (SwiftUI's
            // own text selection on iOS only copies the whole text; asked for on the phone 10/27).
            .contextMenu {
                Button { UIPasteboard.general.string = event.text } label: { Label("拷貝全部", systemImage: "doc.on.doc") }
                Button { selecting = true } label: { Label("選取文字", systemImage: "selection.pin.in.out") }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(mine ? "bubble-user" : "bubble-reply")
            if !mine { Spacer(minLength: 24) }
        }
        .sheet(isPresented: $selecting) { DeskSelectTextSheet(text: event.text) }
    }

    @State private var selecting = false

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Bare web addresses become tappable too, not only Markdown links (asked on the phone 10/27).
        return DeskText.linkingWebAddresses((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// A Markdown table as the desktop apps draw it: a grey header row, a thin line under each row,
/// long cells wrapping; a table wider than the bubble scrolls sideways.
struct DeskTable: View {
    let header: [String]
    let rows: [[String]]
    /// A column as wide as its longest line, up to this; longer cells wrap.
    private static let widest: CGFloat = 170

    var body: some View {
        let widths = columnWidths()
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], width: widths[column]).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    Divider()
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], width: widths[column])
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("bubble-table")
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(DeskBubble.markdown(text))
            .font(.subheadline)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func columnWidths() -> [CGFloat] {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        return header.indices.map { column in
            let texts = [header[column]] + rows.map { $0[column] }
            let longest = texts.map { text in
                (String(DeskBubble.markdown(text).characters) as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
            return min(Self.widest, max(28, ceil(longest) + 2))
        }
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
                    DeskSelectableText(call.text, style: .caption1, monospaced: true)
                        .accessibilityLabel(call.text)
                }
                if let result {
                    let output = fullText ?? (result.text.isEmpty ? "（沒有輸出）" : result.text)
                    // Long output scrolls inside a box instead of filling the whole chat.
                    ScrollView {
                        DeskSelectableText(output, style: .caption2, monospaced: true)
                            .accessibilityLabel(output)
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
            DeskSelectableText(prompt.text, style: .callout)
                .accessibilityLabel(prompt.text)
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

/// An option question: pick one (or several) per question, or write your own under 其他.
struct DeskQuestionCard: View {
    let question: OptionQuestion
    let busy: String?
    let submit: ([QuestionAnswer]) -> Void
    @State private var picks: [Int: [String]] = [:]
    @State private var others: [Int: String] = [:]

    private func answer(_ index: Int) -> QuestionAnswer {
        let other = (others[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return QuestionAnswer(labels: picks[index] ?? [], other: other.isEmpty ? nil : other)
    }

    private var complete: Bool { question.questions.indices.allSatisfy { !answer($0).isEmpty } }

    private func toggle(_ index: Int, _ label: String, multi: Bool) {
        var chosen = picks[index] ?? []
        if chosen.contains(label) {
            chosen.removeAll { $0 == label }
        } else {
            chosen = multi ? chosen + [label] : [label]
        }
        picks[index] = chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Claude 在等你選擇", systemImage: "list.bullet.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.blue)
            ForEach(Array(question.questions.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = item.header {
                        Text(header).font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    Text(item.question).font(.callout)
                    Text(item.multiSelect ? "可複選" : "選一個").font(.caption2).foregroundStyle(.secondary)
                    ForEach(item.options, id: \.label) { option in
                        let on = (picks[index] ?? []).contains(option.label)
                        Button { toggle(index, option.label, multi: item.multiSelect) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.multiSelect ? (on ? "checkmark.square.fill" : "square")
                                                                   : (on ? "largecircle.fill.circle" : "circle"))
                                    .foregroundStyle(on ? Color.blue : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(.primary)
                                    if let detail = option.description {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy != nil)
                        .accessibilityIdentifier("question-option-\(index)-\(option.label)")
                        .accessibilityValue(on ? "已選" : "未選")
                    }
                    TextField("其他（自己寫）", text: Binding(get: { others[index] ?? "" }, set: { others[index] = $0 }),
                              axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy != nil)
                        .accessibilityIdentifier("question-other-\(index)")
                }
            }
            if let busy {
                Text(busy).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("question-busy")
            } else {
                Button { submit(question.questions.indices.map { answer($0) }) } label: {
                    Text("送出選擇").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!complete)
                .accessibilityIdentifier("question-submit")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("question-card")
    }
}

/// The next-step box's reply buttons: tapping one sends its message like typing it.
struct DeskQuickReplies: View {
    let suggestions: ReplySuggestions
    let send: (ReplySuggestions.Reply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ask = suggestions.ask {
                Text(ask).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions.replies, id: \.self) { reply in
                        Button(reply.label) { send(reply) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("quick-reply-\(reply.label)")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
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
    /// In the order they go out; up to `limit` (1 for helpers before 0.5.11, which take one).
    @Binding var photos: [Data]
    let limit: Int
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    @State private var picked: [PhotosPickerItem] = []
    @State private var preparing = false
    @State private var shooting = false
    @StateObject private var dictation = DeskDictation()
    /// Simulator UI tests have no camera: the camera button hands over a made-up shot instead.
    private static let uiTest = ProcessInfo.processInfo.environment["DESK_UI_TEST"] == "1"
    private var canShoot: Bool { Self.uiTest || UIImagePickerController.isSourceTypeAvailable(.camera) }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty }
    /// With room for one photo only, a new pick replaces the one there.
    private var room: Int { limit <= 1 ? 1 : max(0, limit - photos.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(photos.indices, id: \.self) { index in
                            thumbnail(index)
                        }
                    }
                }
                Text(photos.count > 1 ? "會先依序貼上 \(photos.count) 張照片，再送出文字" : "會先貼上照片，再送出文字")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat-photo-count")
            }
            if let failure = dictation.failure {
                Text(failure).font(.caption2).foregroundStyle(.red).accessibilityIdentifier("chat-mic-failure")
            }
            row
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            preparing = true
            Task {
                var ready: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let photo = DeskPhoto.prepare(data) {
                        ready.append(photo)
                    }
                }
                add(ready)
                preparing = false
                picked = []
            }
        }
        .onDisappear { dictation.cancel() }
        .fullScreenCover(isPresented: $shooting) {
            DeskCamera { image in
                shooting = false
                add([image.flatMap { $0.jpegData(compressionQuality: 0.9) }.flatMap { DeskPhoto.prepare($0) }].compactMap { $0 })
            }
            .ignoresSafeArea()
        }
    }

    private func add(_ ready: [Data]) {
        guard !ready.isEmpty else { return }
        photos = limit <= 1 ? [ready[0]] : Array((photos + ready).prefix(limit))
    }

    private func thumbnail(_ index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: photos[index]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("chat-photo-preview")
            }
            Button { photos.remove(at: index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(2)
            .accessibilityLabel("移除第 \(index + 1) 張照片")
            .accessibilityIdentifier("chat-photo-remove")
        }
    }

    /// The keyboard goes away: speaking needs no keyboard (asked on 10/29). Simulator UI tests
    /// cannot speak: the microphone types a fixed phrase instead.
    private func listen() {
        focused.wrappedValue = false
        if Self.uiTest {
            text += "語音輸入測試"
        } else {
            dictation.toggle($text)
        }
    }

    private func shoot() {
        if Self.uiTest {
            let colors: [UIColor] = [.systemTeal, .systemOrange, .systemPurple]
            let shot = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
                colors[photos.count % colors.count].setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }
            add([shot.jpegData(compressionQuality: 0.9).flatMap { DeskPhoto.prepare($0) }].compactMap { $0 })
        } else {
            shooting = true
        }
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $picked, maxSelectionCount: max(1, room), selectionBehavior: .ordered, matching: .images) {
                Image(systemName: preparing ? "hourglass" : "photo").font(.title3)
            }
            .disabled(room == 0 || preparing)
            .accessibilityLabel(limit > 1 ? "加入照片（最多 \(limit) 張）" : "加入照片")
            .accessibilityIdentifier("chat-photo")
            if canShoot {
                Button(action: shoot) { Image(systemName: "camera").font(.title3) }
                    .disabled(preparing || room == 0)
                    .accessibilityLabel("拍照")
                    .accessibilityIdentifier("chat-camera")
            }
            Button(action: listen) {
                Image(systemName: dictation.listening ? "mic.fill" : "mic").font(.title3)
                    .foregroundStyle(dictation.listening ? Color.red : Color.accentColor)
            }
            .accessibilityLabel(dictation.listening ? "停止語音輸入" : "語音輸入")
            .accessibilityIdentifier("chat-mic")
            TextField(dictation.listening ? "請說話…" : "輸入訊息", text: $text, axis: .vertical)
                .lineLimit(1 ... 6)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .accessibilityIdentifier("chat-input")
            Button {
                dictation.cancel()
                send()
            } label: {
                Image(systemName: "paperplane.fill").font(.title3)
            }
            .disabled(empty || preparing)
            .accessibilityLabel("送出")
            .accessibilityIdentifier("chat-send")
        }
    }
}

/// The camera, for a photo that goes straight into the next message: the shot stays in memory
/// and is never saved to the photo library (asked on 10/29).
struct DeskCamera: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void

        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
