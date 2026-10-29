import DeskRemoteCore
import SwiftUI

/// Presses a button in a window that popped up on the PC, and keeps the outcome readable after
/// the window (and its card) is gone.
@MainActor
final class DeskPopupPresser: ObservableObject {
    @Published private(set) var busy: String?
    @Published private(set) var result: String?

    func press(_ popup: HelperState.Popup, _ button: String, client: HelperClient?, then refresh: () async -> Void) async {
        guard let client else { return }
        busy = popup.id
        result = "正在電腦上按「\(button)」…"
        do {
            let end = try await client.follow(try await client.pressPopup(popup.id, button: button), timeout: 30)
            result = end.state == "failed" ? "沒有成功：\(end.message)" : end.message
        } catch let error as HelperFailure {
            result = "沒有成功：\(DeskText.failure(error))"
        } catch {
            result = "沒有成功：\(DeskText.failure(.unreachable))"
        }
        busy = nil
        await refresh()
        // A success stays a while, then goes; a failure stays until the next press.
        if let shown = result, !shown.hasPrefix("沒有成功") {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if result == shown { result = nil }
        }
    }
}

/// The PC's pop-up windows with their buttons; each press asks once before it happens.
struct DeskPopupList: View {
    let popups: [HelperState.Popup]
    @ObservedObject var presser: DeskPopupPresser
    var compact = false
    let press: (HelperState.Popup, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(popups) { popup in
                DeskPopupCard(popup: popup, busy: presser.busy == popup.id, compact: compact) { press(popup, $0) }
            }
            if let result = presser.result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("沒有成功") ? Color.red : Color.secondary)
                    .accessibilityIdentifier("popup-result")
            }
        }
    }
}

struct DeskPopupCard: View {
    let popup: HelperState.Popup
    let busy: Bool
    var compact = false
    let press: (String) -> Void
    @State private var asking: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("電腦跳出視窗：\(popup.name)", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            if !popup.text.isEmpty {
                Text(popup.text)
                    .font(.footnote)
                    .lineLimit(compact ? 3 : 8)
            }
            if !compact {
                Text("這個視窗開著時，電腦上的桌面版收不到訊息。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            buttons
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popup-card")
        .confirmationDialog("在電腦上按「\(asking ?? "")」？",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { button in
            Button("按「\(button)」") { press(button) }
                .accessibilityIdentifier("popup-confirm")
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text(popup.name)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let layout = popup.buttons.count > 3 ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        layout {
            ForEach(popup.buttons, id: \.self) { button in
                Button(button) { asking = button }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .accessibilityIdentifier("popup-button-\(button)")
            }
            if busy { ProgressView() }
        }
    }
}
