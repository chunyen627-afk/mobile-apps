import DeskRemoteCore
import SwiftUI

/// One PC: what its helper reports, then Claude and Codex.
struct DeskPCView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    @State private var state: HelperState?
    @State private var failure: String?
    /// The PC could not be reached at the last look: retry every 5 s instead of 15.
    @State private var unreachable = false
    @State private var editing: DeskPCEditTarget?
    @StateObject private var elevate = DeskElevateModel()
    @StateObject private var presser = DeskPopupPresser()
    /// The Claude version the user is asked to confirm restarting into.
    @State private var confirmUpdate: String?
    @State private var updating = false
    @State private var updateNote: String?

    var body: some View {
        List {
            if let state, !state.shownPopups.isEmpty || presser.result != nil {
                Section("電腦跳出的視窗") {
                    DeskPopupList(popups: state.shownPopups, presser: presser) { popup, button in
                        Task { await presser.press(popup, button, client: store.client(pcID)) { await refresh() } }
                    }
                }
            }
            Section {
                if let failure {
                    DeskNotice(text: failure, tint: .red)
                        .accessibilityIdentifier("pc-error")
                } else if let state {
                    LabeledContent("電腦", value: state.pc.name)
                    LabeledContent("狀態", value: DeskText.presence(state.presence))
                        .accessibilityIdentifier("pc-presence")
                    LabeledContent("小幫手", value: "\(state.pc.helperVersion)\(state.capabilities == ["read"] ? "（唯讀）" : "")")
                    ForEach(state.warnings, id: \.self) { warning in
                        DeskNotice(text: warning)
                    }
                } else {
                    ProgressView()
                }
            }
            Section("桌面版") {
                ForEach(DeskApp.allCases, id: \.self) { app in
                    NavigationLink(value: DeskRoute.sessions(pcID, app)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName).font(.headline)
                            if let state, let line = DeskText.appState(state.app(app)) {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let state, let line = DeskText.versionLine(app, state.version(app)) {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(state.version(app)?.update == true ? Color.orange : Color.secondary)
                                    .accessibilityIdentifier("app-version-\(app.rawValue)")
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("app-row-\(app.rawValue)")
                }
                // Claude's own "restart to update", pressed only from here (asked 10/30).
                if let state, state.can("update"), let pending = state.version(.claude)?.pending {
                    Button { confirmUpdate = pending } label: {
                        Label("重新啟動以更新 Claude（\(pending)）", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(updating)
                    .accessibilityIdentifier("claude-update")
                }
                if let updateNote {
                    Text(updateNote).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("claude-update-note")
                }
                if state?.can("screen") == true {
                    NavigationLink(value: DeskRoute.screen(pcID)) {
                        Label("看電腦畫面", systemImage: "display")
                    }
                    .accessibilityIdentifier("pc-screen")
                }
            }
            if let state, DeskApp.allCases.contains(where: { state.usage($0) != nil }) {
                Section("額度") {
                    ForEach(DeskApp.allCases, id: \.self) { app in
                        if let shown = store.shownUsage(app, in: state, pcID: pcID) {
                            DeskUsageRows(app: app, usage: shown.usage, from: shown.from)
                        }
                    }
                }
            }
            if state?.can("elevate") == true {
                DeskElevateSection(model: elevate, hasKey: store.hasElevateKey(pcID), decide: { request, allow in
                    Task { await elevate.decide(request, allow: allow, store, pcID) }
                }, remove: { ids in elevate.remove(ids, store, pcID) })
            }
        }
        .deskForegroundLoop(every: 5) {
            if state?.can("elevate") == true { await elevate.refresh(store, pcID) }
        }
        .navigationTitle(store.pc(pcID)?.name ?? "電腦")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("編輯") {
                    if let pc = store.pc(pcID) { editing = .edit(pc) }
                }
            }
        }
        .sheet(item: $editing) { DeskPCEditView(store: store, target: $0) }
        .confirmationDialog("重新啟動 Claude 桌面版並更新？",
                            isPresented: Binding(get: { confirmUpdate != nil }, set: { if !$0 { confirmUpdate = nil } }),
                            titleVisibility: .visible, presenting: confirmUpdate) { _ in
            Button("重新啟動以更新", role: .destructive) { Task { await runUpdate() } }
                .accessibilityIdentifier("claude-update-confirm")
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text("電腦上的 Claude 桌面版會關掉再開成 \(pending)。裡面所有 Claude Code 工作（包括正在跑的）都會中斷；重開後對話都還在。")
        }
        // A window waiting on the PC is looked at more often, so its card goes once it is answered.
        .deskForegroundLoop(every: 15, failing: { unreachable || state?.shownPopups.isEmpty == false }) { await refresh() }
        .refreshable { await refresh() }
        // Updated after Claude's question was answered: the note about the question is old news.
        .onChange(of: state?.version(.claude)?.running) { old, new in
            if old != nil, new != old, !updating, let new { updateNote = "Claude 桌面版已更新為 \(new)" }
        }
    }

    private func runUpdate() async {
        guard let client = store.client(pcID) else { return }
        updating = true
        defer { updating = false }
        updateNote = "正在電腦上按「重新啟動以更新」…"
        do {
            let start = try await client.updateApp(.claude)
            let end = try await client.follow(start, timeout: 300) { status in updateNote = status.message }
            updateNote = end.state == "failed" ? "沒有成功：\(end.message)" : end.message
        } catch let error as HelperFailure {
            updateNote = "沒有成功：\(DeskText.failure(error))"
        } catch {
            updateNote = "沒有成功：\(DeskText.failure(.unreachable))"
        }
        await refresh()
    }

    private func refresh() async {
        guard let client = store.client(pcID) else {
            failure = "沒有連線密碼，請按右上角「編輯」"
            return
        }
        do {
            let fresh = try await client.state()
            store.note(fresh, pcID: pcID)
            state = fresh
            failure = nil
            unreachable = false
            Task { await store.askOthersForUsage(except: pcID) }
            if state?.can("elevate") == true { await elevate.refresh(store, pcID) }
        } catch {
            guard let text = DeskNetwork.shared.failureText(error) else { return }
            failure = text
            unreachable = DeskText.isConnectionFailure((error as? HelperFailure) ?? .unreachable)
        }
    }
}
