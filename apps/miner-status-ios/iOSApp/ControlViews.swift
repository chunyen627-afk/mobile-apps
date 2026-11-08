import MinerStatusCore
import SwiftUI

// Start/stop for machines the source marks as controllable (feature `control`).

/// What the detail screen needs to offer control: the model and the action waiting for its
/// confirmation (owned by the detail screen, so it survives list updates).
struct RemoteControl {
    let model: AppModel
    let pending: Binding<ControlAction?>
}

struct RemoteControlSection: View {
    @ObservedObject var model: AppModel
    let machineId: String
    let report: ControlReport
    @Binding var pending: ControlAction?

    private func request(_ action: ControlAction) { pending = action }

    var body: some View {
        Section {
            if !model.hasControlToken {
                Text("在「資料來源」設定輸入控制密碼後才能使用。").foregroundStyle(.secondary)
                    .accessibilityIdentifier("control-needs-token")
            } else {
                if report.canStart {
                    Button { request(.start) } label: { Label("開始挖礦", systemImage: "play.fill") }
                        .disabled(model.controlInFlight != nil)
                        .accessibilityIdentifier("control-start")
                        .modifier(ControlConfirmation(action: .start, pending: $pending, model: model, machineId: machineId))
                }
                if report.canStop {
                    Button(role: .destructive) { request(.stop) } label: {
                        Label("停止挖礦", systemImage: "stop.fill").foregroundStyle(.red)  // icon red like the text
                    }
                        .disabled(model.controlInFlight != nil)
                        .accessibilityIdentifier("control-stop")
                        .modifier(ControlConfirmation(action: .stop, pending: $pending, model: model, machineId: machineId))
                }
                if model.controlInFlight == machineId {
                    HStack { ProgressView(); Text("傳送中…") }
                }
                if let notice = model.controlNotice, notice.machineId == machineId {
                    Text(notice.text)
                        .foregroundStyle(notice.succeeded ? Color.green : Color.red)
                        .accessibilityIdentifier("control-result")
                }
            }
        } header: {
            Text("遠端控制")
        } footer: {
            Text("開始時一樣由電腦端的保護程式檢查溫度與電源，過熱或沒插電會拒絕；停止會正常結束並還原時脈。每次操作電腦端都會發通知。")
        }
    }
}

/// The confirmation for one control button, attached to that button: on an iPad it opens as a
/// popover pointing at the button (attached to the whole screen it opened over the sidebar).
private struct ControlConfirmation: ViewModifier {
    let action: ControlAction
    @Binding var pending: ControlAction?
    let model: AppModel
    let machineId: String

    func body(content: Content) -> some View {
        content.confirmationDialog(action == .stop ? "停止這台的挖礦？" : "開始這台的挖礦？",
                                   isPresented: Binding(get: { pending == action }, set: { if !$0 { pending = nil } }),
                                   titleVisibility: .visible) {
            Button(action == .stop ? "確定停止挖礦" : "確定開始挖礦", role: action == .stop ? .destructive : nil) {
                Task { await model.sendControl(action, to: machineId) }
            }
            .accessibilityIdentifier("confirm-control")
            Button("取消", role: .cancel) {}
        } message: {
            Text(action == .stop ? "電腦端的保護程式會停止礦工並還原時脈。" : "電腦端的保護程式會先檢查溫度與電源，不安全時會拒絕。")
        }
    }
}
