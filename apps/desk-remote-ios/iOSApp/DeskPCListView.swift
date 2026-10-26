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
                NavigationLink(value: DeskRoute.pc(pc.id)) {
                    DeskPCRow(store: store, pc: pc)
                }
                .accessibilityIdentifier("pc-row-\(pc.name)")
                .swipeActions {
                    Button(role: .destructive) { store.delete(pc.id) } label: { Label("移除", systemImage: "trash") }
                    Button { editing = .edit(pc) } label: { Label("編輯", systemImage: "pencil") }
                }
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
        .deskForegroundLoop(every: 30) { await refresh() }
    }

    private func refresh() async {
        guard let client = store.client(pc.id) else {
            line = "沒有連線密碼，請編輯這台電腦"
            healthy = false
            return
        }
        do {
            let state = try await client.state()
            line = "連線正常・\(DeskText.presence(state.presence))"
            healthy = true
        } catch let failure as HelperFailure {
            if failure == .cancelled { return }
            line = DeskText.failure(failure)
            healthy = false
        } catch {
            line = DeskText.failure(.unreachable)
            healthy = false
        }
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
    @State private var saveFailed = false

    private var existing: DeskPC? {
        if case .edit(let pc) = target { return pc }
        return nil
    }

    private var problem: String? {
        DeskPC.problem(name: name, host: host, port: port, token: token, tokenRequired: existing == nil)
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
                    SecureField(existing == nil ? "連線密碼" : "連線密碼（留空表示不變）", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pc-token")
                } header: {
                    Text("連線密碼")
                } footer: {
                    Text("電腦端 config.json 裡的 token。只存在這支手機的鑰匙圈，不會顯示出來。")
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
        if store.save(pc, token: token) {
            dismiss()
        } else {
            saveFailed = true
        }
    }
}
