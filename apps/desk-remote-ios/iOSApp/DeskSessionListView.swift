import DeskRemoteCore
import SwiftUI

/// One desktop app's conversations on one PC, newest first, refreshed every 10 s; "+" starts a
/// new conversation on the PC and opens it here.
struct DeskSessionListView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    let app: DeskApp
    let openChat: (SessionSummary) -> Void
    @State private var list: SessionList?
    @State private var failure: String?
    @State private var composing = false

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
                ForEach(list.sessions) { session in
                    NavigationLink(value: DeskRoute.chat(pcID, app, session)) {
                        DeskSessionRow(session: session)
                    }
                    .disabled(!session.hasTranscript)
                    .accessibilityIdentifier("session-row-\(session.id)")
                }
            } else if failure == nil {
                ProgressView()
            }
        }
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
        .deskForegroundLoop(every: 10) { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        guard let client = store.client(pcID) else {
            failure = "沒有連線密碼"
            return
        }
        do {
            list = try await client.sessions(app)
            failure = nil
        } catch let error as HelperFailure {
            if error != .cancelled { failure = DeskText.failure(error) }
        } catch {
            failure = DeskText.failure(.unreachable)
        }
    }
}

struct DeskSessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
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
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("new-session-status")
                }
            }
            .navigationTitle("新對話")
            .navigationBarTitleDisplayMode(.inline)
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
            let first = try await client.newSession(app, text: text, clientMsgId: clientId, force: force)
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
