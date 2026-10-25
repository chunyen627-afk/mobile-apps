import MinerStatusCore
import SwiftUI

// Start/stop for machines the source marks as controllable (feature `control`).

/// What the detail screen needs to offer control: the model and a way to ask for confirmation.
struct RemoteControl {
    let model: AppModel
    let request: (ControlAction) -> Void
}

struct RemoteControlSection: View {
    @ObservedObject var model: AppModel
    let machineId: String
    let report: ControlReport
    let request: (ControlAction) -> Void

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
                }
                if report.canStop {
                    Button(role: .destructive) { request(.stop) } label: {
                        Label("停止挖礦", systemImage: "stop.fill").foregroundStyle(.red)  // icon red like the text
                    }
                        .disabled(model.controlInFlight != nil)
                        .accessibilityIdentifier("control-stop")
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
