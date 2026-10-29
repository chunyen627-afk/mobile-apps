import DeskRemoteCore
import SwiftUI

/// First screen: every PC with a live connection line, plus adding, editing and removing PCs.
struct DeskPCListView: View {
    @ObservedObject var store: DeskStore
    @State private var editing: DeskPCEditTarget?

    var body: some View {
        List {
            if store.pcs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("還沒有電腦").font(.headline)
                    Text("在電腦上安裝桌面遙控小幫手後，按右上角「＋」輸入它的位址與連線密碼。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pc-empty")
            }
            ForEach(store.pcs) { pc in
                Section {
                    NavigationLink(value: DeskRoute.pc(pc.id)) {
                        DeskPCRow(store: store, pc: pc)
                    }
                    .accessibilityIdentifier("pc-row-\(pc.name)")
                    .swipeActions {
                        Button(role: .destructive) { store.delete(pc.id) } label: { Label("移除", systemImage: "trash") }
                        Button { editing = .edit(pc) } label: { Label("編輯", systemImage: "pencil") }
                    }
                    // Each desktop app's last conversation, straight into its list (asked 10/29:
                    // see from the first screen which of the four was written to).
                    ForEach(DeskApp.allCases, id: \.self) { app in
                        if let latest = store.latest(pc.id, app) {
                            NavigationLink(value: DeskRoute.sessions(pc.id, app)) {
                                DeskLatestRow(app: app, latest: latest, new: store.isNew(pc.id, app))
                            }
                            .accessibilityIdentifier("pc-latest-\(pc.name)-\(app.rawValue)")
                            .accessibilityValue(store.isNew(pc.id, app) ? "有新訊息" : "")
                        }
                    }
                }
            }
            // The app's own version (the PC page's "小幫手" line is the helper's, read as the app's 10/27).
            Section {
            } footer: {
                Text(DeskText.appVersion(Bundle.main.infoDictionary ?? [:]))
                    .accessibilityIdentifier("app-version")
            }
        }
        .navigationTitle("桌面遙控")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .add } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新增電腦")
                    .accessibilityIdentifier("pc-add")
            }
        }
        .sheet(item: $editing) { target in
            DeskPCEditView(store: store, target: target)
        }
    }
}

/// One PC: its name, then what its helper reports, refreshed every 30 s in the foreground.
struct DeskPCRow: View {
    @ObservedObject var store: DeskStore
    let pc: DeskPC
    @State private var line = "連線中…"
    @State private var healthy: Bool?
    /// The PC could not be reached at the last look: retry every 5 s instead of 30.
    @State private var unreachable = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(healthy == true ? Color.green : healthy == false ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(pc.name).font(.headline)
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .deskForegroundLoop(every: 30, failing: { unreachable }) { await refresh() }
    }

    private func refresh() async {
        guard let client = store.client(pc.id) else {
            line = "沒有連線密碼，請編輯這台電腦"
            healthy = false
            return
        }
        do {
            let state = try await client.state()
            store.note(state, pcID: pc.id)
            line = "連線正常・\(DeskText.presence(state.presence))"
            if let waiting = state.elevate?.pending, waiting > 0 {
                line += "・\(waiting) 個管理員權限請求"
            }
            healthy = true
            unreachable = false
        } catch {
            guard let text = DeskNetwork.shared.failureText(error, short: true) else { return }
            line = text
            healthy = false
            unreachable = DeskText.isConnectionFailure((error as? HelperFailure) ?? .unreachable)
        }
    }
}

/// One app's last conversation: a blue dot when it was written after the user last looked,
/// then the app, its time ("回覆中", "5 分鐘前") and the conversation's title.
struct DeskLatestRow: View {
    let app: DeskApp
    let latest: HelperState.Latest
    let new: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(new ? Color.blue : Color.clear)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.displayName)
                        .font(.subheadline.weight(new ? .semibold : .regular))
                    Spacer()
                    // "5 分鐘前" keeps counting while the PC reports nothing new.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(DeskText.latestTime(latest, now: context.date))
                            .font(.footnote)
                            .foregroundStyle(latest.status == "needs-action" ? Color.orange : latest.status == "active" ? Color.green : Color.secondary)
                    }
                }
                Text(latest.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum DeskPCEditTarget: Identifiable {
    case add
    case edit(DeskPC)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let pc): return pc.id.uuidString
        }
    }
}

/// Add or edit a PC. The token field is never filled back in; leaving it empty keeps the stored one.
struct DeskPCEditView: View {
    @ObservedObject var store: DeskStore
    let target: DeskPCEditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = String(DeskPC.defaultPort)
    @State private var token = ""
    @State private var elevateKey = ""
    @State private var removeElevateKey = false
    @State private var saveFailed = false

    private var existing: DeskPC? {
        if case .edit(let pc) = target { return pc }
        return nil
    }

    private var existingKey: Bool { existing.map { store.hasElevateKey($0.id) } ?? false }

    private var problem: String? {
        if let problem = DeskPC.problem(name: name, host: host, port: port, token: token, tokenRequired: existing == nil) {
            return problem
        }
        if !elevateKey.filter({ !$0.isWhitespace }).isEmpty && ElevateSigner.key(fromHex: elevateKey) == nil {
            return "管理員核准金鑰要是 64 個十六進位字元（安裝提權夥伴時顯示的那一串）"
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名稱（例如：辦公室）", text: $name)
                        .accessibilityIdentifier("pc-name")
                    TextField("位址（私人網路 IP）", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pc-host")
                    TextField("埠", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("pc-port")
                } header: {
                    Text("電腦")
                } footer: {
                    Text("只在私人網路（ZeroTier）裡連線，位址只存在這支手機。")
                }
                Section {
                    // Not a login password: without this, two secure fields made iOS offer a
                    // "strong password", which took over the typing (found by the UI tests).
                    SecureField(existing == nil ? "連線密碼" : "連線密碼（留空表示不變）", text: $token)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pc-token")
                } header: {
                    Text("連線密碼")
                } footer: {
                    Text("電腦端 config.json 裡的 token。只存在這支手機的鑰匙圈，不會顯示出來。")
                }
                Section {
                    SecureField(existingKey ? "管理員核准金鑰（已設定，留空表示不變）" : "管理員核准金鑰（選填）", text: $elevateKey)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(removeElevateKey)
                        .accessibilityIdentifier("pc-elevate-key")
                    if existingKey {
                        Toggle("移除這台電腦的管理員核准金鑰", isOn: $removeElevateKey)
                    }
                } header: {
                    Text("管理員權限")
                } footer: {
                    Text("用系統管理員身分執行 install-elevated.ps1 時顯示的 64 個字元。有了它，這支手機才能用 Face ID 核准 elevate 指令；它和連線密碼分開存，電腦上的小幫手拿不到。")
                }
                if let problem, !(name.isEmpty && host.isEmpty && existing == nil) {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("pc-form-problem")
                }
                if saveFailed {
                    Text("無法存入鑰匙圈，請再試一次")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(existing == nil ? "新增電腦" : "編輯電腦")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }
                        .disabled(problem != nil)
                        .accessibilityIdentifier("pc-save")
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    host = existing.host
                    port = String(existing.port)
                }
            }
        }
    }

    private func save() {
        guard problem == nil, let number = Int(port.trimmingCharacters(in: .whitespaces)) else { return }
        let pc = DeskPC(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces),
                        host: host.trimmingCharacters(in: .whitespaces), port: number)
        guard store.save(pc, token: token) else {
            saveFailed = true
            return
        }
        if removeElevateKey {
            _ = store.saveElevateKey("", for: pc.id)
        } else if !elevateKey.filter({ !$0.isWhitespace }).isEmpty, !store.saveElevateKey(elevateKey, for: pc.id) {
            saveFailed = true
            return
        }
        dismiss()
    }
}
