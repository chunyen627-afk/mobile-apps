import DeskRemoteCore
import SwiftUI
import UIKit

/// Administrator commands waiting for this phone (elevate). Approving needs Face ID (or the
/// passcode) and this PC's approval key; the signature is made here over the content shown,
/// so the PC runs exactly what was approved or nothing. The PC page owns the 5-second refresh
/// loop: a `.task` on a List section did not run reliably (found by the UI tests).
@MainActor
final class DeskElevateModel: ObservableObject {
    @Published private(set) var list: ElevateList?
    @Published private(set) var failure: String?
    @Published private(set) var busy: [String: String] = [:]
    @Published var expanded: Set<String> = []

    func refresh(_ store: DeskStore, _ pcID: UUID) async {
        guard let client = store.client(pcID) else { return }
        do {
            list = try await client.elevateList()
            failure = nil
        } catch let error as HelperFailure {
            if error != .cancelled { failure = DeskText.failure(error) }
        } catch {
            failure = DeskText.failure(.unreachable)
        }
    }

    func decide(_ request: ElevateRequest, allow: Bool, _ store: DeskStore, _ pcID: UUID) async {
        guard let client = store.client(pcID) else { return }
        var signature: String?
        if allow {
            guard let key = store.elevateKey(pcID) else {
                busy[request.id] = "這支手機沒有這台電腦的管理員核准金鑰"
                return
            }
            guard await store.confirmOwner(reason: "核准以系統管理員身分執行這個指令") else {
                busy[request.id] = "沒有通過 Face ID，未核准"
                return
            }
            signature = ElevateSigner.signature(key: key, for: request)
        }
        busy[request.id] = allow ? "已核准，執行中…" : "正在拒絕…"
        do {
            try await client.decideElevate(request.id, allow: allow, signature: signature)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch let error as HelperFailure {
            busy[request.id] = "沒有成功：\(DeskText.failure(error))"
        } catch {
            busy[request.id] = "沒有成功：\(DeskText.failure(.unreachable))"
        }
        await refresh(store, pcID)
    }
}

struct DeskElevateSection: View {
    @ObservedObject var model: DeskElevateModel
    let hasKey: Bool
    let decide: (ElevateRequest, Bool) -> Void

    var body: some View {
        Section {
            if let failure = model.failure {
                DeskNotice(text: failure, tint: .red)
            }
            if let list = model.list {
                if !list.available {
                    DeskNotice(text: "提權夥伴沒有回應（排程工作 DeskRemoteElevated 沒在執行？）")
                }
                if list.pending.isEmpty {
                    Text("沒有在等核准的指令").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("elevate-empty")
                }
                ForEach(list.pending) { request in
                    DeskElevateCard(request: request, hasKey: hasKey, busy: model.busy[request.id]) { allow in
                        decide(request, allow)
                    }
                }
                ForEach(list.recent) { result in
                    DeskElevateResultRow(result: result, expanded: model.expanded.contains(result.id)) {
                        if model.expanded.contains(result.id) {
                            model.expanded.remove(result.id)
                        } else {
                            model.expanded.insert(result.id)
                        }
                    }
                }
            } else if model.failure == nil {
                ProgressView()
            }
        } header: {
            Text("管理員權限（elevate）")
        } footer: {
            Text("AI 用 elevate 要求以系統管理員身分執行的指令會出現在這裡。允許前請看清楚內容。")
        }
    }
}

struct DeskElevateCard: View {
    let request: ElevateRequest
    let hasKey: Bool
    let busy: String?
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.kind == "script" ? "要以系統管理員身分執行腳本 \(request.name)" : "要以系統管理員身分執行",
                  systemImage: "lock.shield.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.red)
            ScrollView {
                Text(request.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .accessibilityIdentifier("elevate-content")
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: request.content.count < 400)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
            Text("資料夾：\(request.cwd.isEmpty ? "（未指定）" : request.cwd)・\(DeskText.remaining(until: request.expires))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let busy {
                Text(busy).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("elevate-busy")
            } else {
                if !hasKey {
                    Text("這支手機沒有這台電腦的管理員核准金鑰，只能拒絕。請在「編輯」輸入金鑰。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("elevate-no-key")
                }
                HStack(spacing: 12) {
                    Button { decide(true) } label: {
                        Label("允許", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!hasKey)
                    .accessibilityIdentifier("elevate-allow")
                    Button { decide(false) } label: { Text("拒絕").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("elevate-deny")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("elevate-card")
    }
}

struct DeskElevateResultRow: View {
    let result: ElevateResult
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack {
                    Image(systemName: result.state == "done" && result.exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(result.state == "done" && result.exitCode == 0 ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DeskText.elevateState(result)).font(.footnote.bold())
                        Text(result.content.split(separator: "\n").first.map(String.init) ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("elevate-result")
            if expanded {
                Text(result.output.isEmpty ? "（沒有輸出）" : result.output)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("elevate-output")
            }
        }
    }
}
