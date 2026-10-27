import DeskRemoteCore
import SwiftUI

/// The chat's top line: model, effort and context use; tapping it opens the details.
struct DeskMetaBar: View {
    let line: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.caption)
                Text(line).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-meta")
    }
}

/// Plan limits of one app as bars: "每週 46%・週日上午11:00 重設".
struct DeskUsageRows: View {
    let app: DeskApp
    let usage: PlanUsage

    var body: some View {
        ForEach(usage.windows, id: \.self) { window in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(app.displayName)・\(DeskText.usageWindow(window))").font(.footnote)
                ProgressView(value: Double(min(max(window.percent, 0), 100)), total: 100)
                    .tint(window.percent >= 90 ? .red : window.percent >= 70 ? .orange : .accentColor)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usage-\(app.rawValue)")
        }
        if let sampled = DeskText.relative(usage.sampledAt) {
            Text("\(app.displayName) 額度資料：\(sampled)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// This conversation's model, effort and context use, the app's plan limits, and (for Claude)
/// switching the model on the PC through its own model menu.
struct DeskModelSheet: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    let app: DeskApp
    let session: SessionSummary
    let meta: ConversationMeta?
    @Environment(\.dismiss) private var dismiss
    @State private var state: HelperState?
    @State private var failure: String?
    @State private var busy: [DeskPick: String] = [:]
    @State private var working = false
    @State private var confirm: DeskConfirm?

    var body: some View {
        NavigationStack {
            List {
                Section("這個對話") {
                    LabeledContent("模型", value: meta?.model ?? "不知道")
                        .accessibilityIdentifier("meta-model")
                    if let effort = meta?.effort {
                        LabeledContent("推理強度", value: effort)
                    }
                    if let permission = meta?.permission {
                        LabeledContent("權限模式", value: permission)
                            .accessibilityIdentifier("meta-permission")
                    }
                    if let context = meta?.context {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DeskText.context(context)).font(.footnote)
                            if let percent = context.percent {
                                ProgressView(value: Double(min(percent, 100)), total: 100)
                                    .tint(percent >= 80 ? .orange : .accentColor)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("meta-context")
                    } else {
                        Text("上下文用量：還沒有回覆可以計算").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("額度") {
                    if let usage = state?.usage(app) {
                        DeskUsageRows(app: app, usage: usage)
                    } else if let failure {
                        DeskNotice(text: failure, tint: .red)
                    } else if state == nil {
                        ProgressView()
                    } else {
                        Text("電腦端沒有這個 App 的額度資料").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(DeskPick.allCases, id: \.self) { kind in
                    let options = state.map { kind.options($0, app) } ?? []
                    if !options.isEmpty {
                        Section {
                            ForEach(options, id: \.self) { option in
                                Button { Task { await pick(kind, option, force: false) } } label: {
                                    HStack {
                                        Text(option).foregroundStyle(.primary)
                                        Spacer()
                                        if option == kind.current(meta) {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .disabled(working)
                                .accessibilityIdentifier("\(kind.rawValue)-\(option)")
                            }
                            if let note = busy[kind] {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("\(kind.rawValue)-busy")
                            }
                        } header: {
                            Text(kind.title)
                        } footer: {
                            Text(kind.footer(app))
                        }
                    }
                }
            }
            .navigationTitle("模型與用量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("meta-done")
                }
            }
            .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                   presenting: confirm) { item in
                Button(item.confirmLabel) { Task { await item.run() } }
                Button("取消", role: .cancel) { item.cancel() }
            } message: { item in
                Text(item.message)
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let client = store.client(pcID) else { return }
        do {
            state = try await client.state()
            failure = nil
        } catch let error as HelperFailure {
            if error != .cancelled { failure = DeskText.failure(error) }
        } catch {
            failure = DeskText.failure(.unreachable)
        }
    }

    private func pick(_ kind: DeskPick, _ option: String, force: Bool) async {
        guard let client = store.client(pcID) else { return }
        busy[kind] = "正在電腦上切換為 \(option)…"
        working = true
        defer { working = false }
        do {
            let start: ActionStatus
            switch kind {
            case .model: start = try await client.setModel(app, session: session.id, model: option, force: force)
            case .effort: start = try await client.setEffort(app, session: session.id, effort: option, force: force)
            case .mode: start = try await client.setMode(app, session: session.id, mode: option, force: force)
            }
            let end = try await client.follow(start, timeout: 60) { status in busy[kind] = status.message }
            busy[kind] = end.state == "failed" ? "沒有成功：\(end.message)" : end.message
        } catch HelperFailure.busyUser(let seconds) {
            busy[kind] = nil
            confirm = DeskConfirm(
                title: "電腦有人在用",
                message: "\(seconds.map { "\($0) 秒前" } ?? "剛剛")有人操作過這台電腦。切換會切換電腦畫面上的對話並點選選單。",
                confirmLabel: "仍要切換",
                run: { await pick(kind, option, force: true) },
                cancel: {})
        } catch let error as HelperFailure {
            busy[kind] = "沒有成功：\(DeskText.failure(error))"
        } catch {
            busy[kind] = "沒有成功：\(DeskText.failure(.unreachable))"
        }
    }
}

/// What the model sheet can switch on the PC, each from its own menu there.
enum DeskPick: String, CaseIterable, Hashable {
    case model, effort, mode

    var title: String {
        switch self {
        case .model: return "切換模型"
        case .effort: return "推理強度"
        case .mode: return "權限模式"
        }
    }

    func options(_ state: HelperState, _ app: DeskApp) -> [String] {
        switch self {
        case .model: return state.models(app)
        case .effort: return state.efforts(app)
        case .mode: return state.modes(app)
        }
    }

    /// The option the conversation uses now; effort options read "中" while the menu also says "推薦".
    func current(_ meta: ConversationMeta?) -> String? {
        switch self {
        case .model: return meta?.model
        case .effort: return meta?.effort
        case .mode: return meta?.permission
        }
    }

    func footer(_ app: DeskApp) -> String {
        switch self {
        case .model: return "會在電腦上打開這個對話、點開模型選單選好；只影響這個對話之後的回覆。"
        case .effort: return "越高回答越仔細，但越慢、越耗額度。"
        case .mode:
            return app == .codex
                ? "Codex 不會在畫面上顯示目前的模式，選了之後從下一則回覆起生效。"
                : "「略過權限確認」與「自動」不會再問你；「手動」每次變更都會問。"
        }
    }
}
