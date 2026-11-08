import DeskRemoteCore
import SwiftUI

/// One desktop app's conversations on one PC, newest first, refreshed every 10 s; "+" starts a
/// new conversation on the PC and opens it here. Coming in while the desktop app has no window
/// (closed, or closed to the tray) opens it on the PC, quietly and unless someone is using the
/// PC: actions bring it up anyway, so how it went is not said.
struct DeskSessionListView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    let app: DeskApp
    let openChat: (SessionSummary) -> Void
    @State private var list: SessionList?
    @State private var failure: String?
    /// The PC could not be reached at the last look: retry every 5 s instead of 10.
    @State private var unreachable = false
    @State private var composing = false
    @State private var launchTried = false
    /// When the user had last looked before this visit: conversations written since get a dot.
    @State private var seenBefore: String?
    @State private var visited = false

    var body: some View {
        List {
            if let failure {
                DeskNotice(text: failure, tint: .red)
                    .accessibilityIdentifier("sessions-error")
            }
            if let warning = list?.warning {
                DeskNotice(text: warning)
                    .accessibilityIdentifier("sessions-warning")
            }
            if let list {
                if list.sessions.isEmpty {
                    Text("沒有對話").foregroundStyle(.secondary)
                }
                // A section per day and conversations started from another one nested under it,
                // as the desktop's sidebar shows them (asked 11/1).
                ForEach(SessionTree.build(list.sessions).sections) { section in
                    Section(SessionTree.dayLabel(section.day, today: SessionTree.dayKey(Date()))) {
                        ForEach(section.rows) { row in
                            NavigationLink(value: DeskRoute.chat(pcID, app, row.session)) {
                                HStack(spacing: 0) {
                                    if row.depth > 0 {
                                        DeskTreeLine(depth: row.depth, last: row.last)
                                    }
                                    DeskSessionRow(session: row.session,
                                                   new: row.session.status != "active" && !store.opened.contains(row.session.id)
                                                        && DeskText.isNewer(row.session.updatedAt ?? "", than: seenBefore))
                                }
                            }
                            .disabled(!row.session.hasTranscript)
                            .accessibilityIdentifier("session-row-\(row.session.id)")
                        }
                    }
                }
            } else if failure == nil {
                ProgressView()
            }
        }
        .modifier(ReadableListWidth())
        .navigationTitle(app.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("新對話")
                    .accessibilityIdentifier("new-session")
            }
        }
        .sheet(isPresented: $composing) {
            DeskNewSessionView(store: store, pcID: pcID, app: app) { session in
                composing = false
                openChat(session)
            }
        }
        .deskForegroundLoop(every: 10, failing: { unreachable }) { await refresh() }
        .refreshable { await refresh() }
        .task { await launchIfClosed() }
        .onAppear {
            if !visited {
                visited = true
                seenBefore = store.seen["\(pcID.uuidString)/\(app.rawValue)"]
            }
            store.markSeen(pcID, app)
        }
        .onDisappear { store.markSeen(pcID, app) }
    }

    /// Once per visit: only when the helper can open it and says it has no window.
    private func launchIfClosed() async {
        guard !launchTried, let client = store.client(pcID) else { return }
        launchTried = true
        guard let state = try? await client.state(), state.can("launch"), state.app(app)?.running == false else { return }
        _ = try? await client.launch(app)
    }

    private func refresh() async {
        guard let client = store.client(pcID) else {
            failure = "沒有連線密碼"
            return
        }
        do {
            list = try await client.sessions(app)
            failure = nil
            unreachable = false
        } catch {
            guard let text = DeskNetwork.shared.failureText(error) else { return }
            failure = text
            unreachable = DeskText.isConnectionFailure((error as? HelperFailure) ?? .unreachable)
        }
    }
}

/// The branch lines in front of a nested conversation: a vertical line per level, an elbow
/// into this row (the line stops at the last child).
struct DeskTreeLine: View {
    let depth: Int
    let last: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0 ..< depth, id: \.self) { level in
                ZStack(alignment: .topLeading) {
                    if level < depth - 1 {
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1)
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1)
                            .frame(maxHeight: last ? 14 : .infinity, alignment: .top)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 10, height: 1)
                            .offset(y: 13)
                    }
                }
                .frame(width: 16)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel("由上面的對話啟動")
        .accessibilityIdentifier("tree-line")
    }
}

struct DeskSessionRow: View {
    let session: SessionSummary
    var new = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if new {
                    Circle().fill(Color.blue).frame(width: 8, height: 8)
                        .accessibilityLabel("新")
                }
                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let status = DeskText.sessionStatus(session.status) {
                    Text(status)
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(session.status == "needs-action" ? Color.orange.opacity(0.2) : Color.green.opacity(0.2),
                                    in: Capsule())
                }
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let folder = session.folder { parts.append(folder) }
        if let time = DeskText.relative(session.updatedAt) { parts.append(time) }
        if let permission = session.permission { parts.append(permission) }
        if !session.hasTranscript { parts.append("找不到逐字稿") }
        return parts.joined(separator: "・")
    }
}

/// The first message of a new conversation. The PC opens a new conversation in the desktop app
/// (its default folder) and pastes the message.
struct DeskNewSessionView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    let app: DeskApp
    let opened: (SessionSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var status: String?
    @State private var working = false
    @State private var confirmBusy: Int??
    @State private var pcState: HelperState?
    @State private var model: String?
    @State private var effort: String?
    private let clientId = UUID().uuidString

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("第一則訊息", text: $text, axis: .vertical)
                        .lineLimit(4 ... 12)
                        .accessibilityIdentifier("new-session-text")
                } footer: {
                    Text("電腦上的 \(app.displayName) 會開一個新對話（使用桌面版目前預設的資料夾），貼上這段文字並送出。")
                }
                // The model and effort are picked on the new conversation's empty page before the
                // first message (helper 0.5.36; the user 11/8: choose them when opening, not after).
                if let pcState, !pcState.models(app).isEmpty || !pcState.efforts(app).isEmpty {
                    Section {
                        if !pcState.models(app).isEmpty {
                            DeskNewSessionPick(title: "模型", options: pcState.models(app), choice: $model)
                                .accessibilityIdentifier("new-session-model")
                        }
                        if !pcState.efforts(app).isEmpty {
                            DeskNewSessionPick(title: "推理強度", options: pcState.efforts(app), choice: $effort)
                                .accessibilityIdentifier("new-session-effort")
                        }
                    } footer: {
                        Text("沒選就照桌面版目前的設定。")
                    }
                }
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("new-session-status")
                }
            }
            .navigationTitle("新對話")
            .navigationBarTitleDisplayMode(.inline)
            .task { pcState = try? await store.client(pcID)?.state() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送出") { Task { await start(force: false) } }
                        .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("new-session-send")
                }
            }
            .alert("電腦有人在用", isPresented: Binding(get: { confirmBusy != nil }, set: { if !$0 { confirmBusy = nil } })) {
                Button("仍要送出") { Task { await start(force: true) } }
                Button("取消", role: .cancel) { status = "已取消，沒有送出" }
            } message: {
                Text("\((confirmBusy ?? nil).map { "\($0) 秒前" } ?? "剛剛")有人操作過這台電腦。開新對話會把視窗切到前面。")
            }
        }
    }

    private func start(force: Bool) async {
        guard let client = store.client(pcID) else { return }
        working = true
        defer { working = false }
        status = "送出中…"
        do {
            let first = try await client.newSession(app, text: text, clientMsgId: clientId, model: model, effort: effort, force: force)
            let end = try await client.follow(first, timeout: 60) { status = $0.message }
            status = end.message
            if end.state == "done", let id = end.sessionId {
                opened(SessionSummary(id: id, title: end.title ?? "新對話"))
            }
        } catch HelperFailure.busyUser(let seconds) {
            status = nil
            confirmBusy = .some(seconds)
        } catch let error as HelperFailure {
            status = "沒有送出：\(DeskText.failure(error))"
        } catch {
            status = "沒有送出：\(DeskText.failure(.unreachable))"
        }
    }
}

/// One choice for the new conversation: the desktop app's current setting (nil) or one option.
struct DeskNewSessionPick: View {
    let title: String
    let options: [String]
    @Binding var choice: String?

    var body: some View {
        Picker(title, selection: $choice) {
            Text("照目前的").tag(String?.none)
            ForEach(options, id: \.self) { option in
                Text(option).tag(String?.some(option))
            }
        }
    }
}

/// On a wide screen (an iPad in landscape) the list keeps a readable width in the middle instead
/// of stretching edge to edge; on an iPhone, or an iPad mini in portrait, nothing changes. Safe-area
/// padding, not content margins: a zero margin would also drop the list's own insets.
fileprivate struct ReadableListWidth: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.horizontal, width > 820 ? (width - 720) / 2 : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
