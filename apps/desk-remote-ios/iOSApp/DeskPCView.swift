import DeskRemoteCore
import SwiftUI

/// One PC: what its helper reports, then Claude and Codex.
struct DeskPCView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    @State private var state: HelperState?
    @State private var failure: String?
    @State private var editing: DeskPCEditTarget?
    @StateObject private var elevate = DeskElevateModel()

    var body: some View {
        List {
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
                            Text(state.map { DeskText.appState($0.app(app)) } ?? " ")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("app-row-\(app.rawValue)")
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
                        if let usage = state.usage(app) {
                            DeskUsageRows(app: app, usage: usage)
                        }
                    }
                }
            }
            if state?.can("elevate") == true {
                DeskElevateSection(model: elevate, hasKey: store.hasElevateKey(pcID)) { request, allow in
                    Task { await elevate.decide(request, allow: allow, store, pcID) }
                }
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
        .deskForegroundLoop(every: 15) { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        guard let client = store.client(pcID) else {
            failure = "沒有連線密碼，請按右上角「編輯」"
            return
        }
        do {
            state = try await client.state()
            failure = nil
            if state?.can("elevate") == true { await elevate.refresh(store, pcID) }
        } catch let error as HelperFailure {
            if error != .cancelled { failure = DeskText.failure(error) }
        } catch {
            failure = DeskText.failure(.unreachable)
        }
    }
}
