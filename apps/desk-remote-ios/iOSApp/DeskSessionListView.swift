import DeskRemoteCore
import SwiftUI

/// One desktop app's conversations on one PC, newest first, refreshed every 10 s.
struct DeskSessionListView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    let app: DeskApp
    @State private var list: SessionList?
    @State private var failure: String?

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
