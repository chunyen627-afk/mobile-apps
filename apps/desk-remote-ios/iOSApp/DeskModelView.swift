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
    @State private var busy: String?
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
                let models = state?.models(app) ?? []
                if !models.isEmpty {
                    Section {
                        ForEach(models, id: \.self) { model in
                            Button { Task { await pick(model, force: false) } } label: {
                                HStack {
                                    Text(model).foregroundStyle(.primary)
                                    Spacer()
                                    if model == meta?.model { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .disabled(working)
                            .accessibilityIdentifier("model-\(model)")
                        }
                        if let busy {
                            Text(busy).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("model-busy")
                        }
                    } header: {
                        Text("切換模型")
                    } footer: {
                        Text("會在電腦上打開這個對話、點開模型選單選好；只影響這個對話之後的回覆。")
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

    private func pick(_ model: String, force: Bool) async {
        guard let client = store.client(pcID) else { return }
        busy = "正在電腦上切換為 \(model)…"
        working = true
        defer { working = false }
        do {
            let start = try await client.setModel(app, session: session.id, model: model, force: force)
            let end = try await client.follow(start, timeout: 60) { status in busy = status.message }
            busy = end.state == "failed" ? "沒有成功：\(end.message)" : end.message
        } catch HelperFailure.busyUser(let seconds) {
            busy = nil
            confirm = DeskConfirm(
                title: "電腦有人在用",
                message: "\(seconds.map { "\($0) 秒前" } ?? "剛剛")有人操作過這台電腦。切換模型會切換電腦畫面上的對話並點選選單。",
                confirmLabel: "仍要切換",
                run: { await pick(model, force: true) },
                cancel: {})
        } catch let error as HelperFailure {
            busy = "沒有成功：\(DeskText.failure(error))"
        } catch {
            busy = "沒有成功：\(DeskText.failure(.unreachable))"
        }
    }
}
