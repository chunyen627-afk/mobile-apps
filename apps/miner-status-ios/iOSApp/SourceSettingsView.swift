// NOT COMPILED, NOT VISUALLY TESTED: written without Swift/Xcode available.

import MinerStatusCore
import SwiftUI

/// The source URL and interval are stored only on this device (UserDefaults). There is no default
/// address, and saving never connects: only the explicit start button does.
struct SourceSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sourceURL") private var urlText = ""
    @AppStorage("pollIntervalSeconds") private var pollSeconds = 30

    private var validation: Result<SourceEndpoint, SourceEndpointError> {
        do {
            return .success(try SourceEndpoint(validating: urlText))
        } catch let error as SourceEndpointError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("每次開啟 App 都是離線示範。只有按下「開始讀取」才會連到下方網址；App 只送出 GET 讀取請求，不傳送帳密、不控制礦機。")
                        .font(.footnote)
                }

                Section {
                    HStack {
                        TextField("http://主機名稱:埠/status", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("source-url")
                        if !urlText.isEmpty {
                            Button { urlText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("清除網址")
                            .accessibilityIdentifier("source-url-clear")
                        }
                    }
                    switch validation {
                    case .success(let endpoint):
                        if endpoint.usesPlainHTTP {
                            Label("HTTP 未加密，只適合受信任的私人網路；iOS 也可能拒絕此連線。", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    case .failure(let error):
                        if !urlText.isEmpty {
                            Text(error.displayText).font(.caption).foregroundStyle(.red)
                                .accessibilityIdentifier("source-url-error")
                        }
                    }
                } header: {
                    Text("來源網址")
                } footer: {
                    Text("來源必須回傳符合白名單格式的 JSON；格式不符的資料一律拒收。")
                }

                Section {
                    Picker("間隔", selection: $pollSeconds) {
                        ForEach(AppModel.pollIntervals.map { Int($0) }, id: \.self) { seconds in
                            Text("\(seconds) 秒").tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    // Without textCase(nil) the grouped header uppercases "App" to "APP".
                    Text("讀取間隔（僅在 App 位於前景時）").textCase(nil)
                }

                Section {
                    Button("開始讀取（唯讀）") {
                        guard case .success(let endpoint) = validation else { return }
                        model.startLive(endpoint: endpoint, pollInterval: TimeInterval(pollSeconds))
                        dismiss()
                    }
                    .disabled(!isValid)
                    .accessibilityIdentifier("start-live")

                    if model.mode == .live {
                        Button("停止讀取並回到離線示範") {
                            model.stopLiveAndReturnToDemo()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("資料來源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }

    private var isValid: Bool {
        if case .success = validation { return true }
        return false
    }
}
