import SwiftUI
import ThermoCore

/// The toolbox's thermometer tab: every thermometer heard by the configured gateways, grouped by
/// gateway, read every 30 seconds while the tab is on screen.
struct ThermoRootView: View {
    @StateObject private var model = ThermoModel()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ThermoListView(model: model) { showingSettings = true }
                .navigationDestination(for: ThermoSensorRef.self) { ref in
                    ThermoDetailView(model: model, ref: ref)
                }
        }
        .sheet(isPresented: $showingSettings) { ThermoSettingsView(model: model) }
        .task { await model.pollWhileVisible() }
    }
}

struct ThermoListView: View {
    @ObservedObject var model: ThermoModel
    let showSettings: () -> Void
    @State private var showHidden = false

    var body: some View {
        List {
            if model.isDemo {
                Section {
                    Label("示範資料：按右上角齒輪填入閘道網址，就會顯示你的溫濕度計。", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("thermo-demo-banner")
                }
            }
            ForEach(model.shown) { gateway in
                gatewaySection(gateway)
            }
            let hidden = model.hiddenRows
            if !hidden.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showHidden) {
                        ForEach(hidden) { item in
                            row(item.gateway, item.sensor)
                        }
                    } label: {
                        Text("已隱藏（\(hidden.count)）").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("thermo-hidden-group")
                }
            }
        }
        .navigationTitle("溫濕度")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("閘道設定")
                .accessibilityIdentifier("thermo-settings")
            }
        }
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private func gatewaySection(_ gateway: ThermoGatewayState) -> some View {
        let visible = model.preferences.arrange(gateway.feed?.sensors ?? []).visible
        Section {
            if let error = gateway.error {
                Label(error.displayText + (gateway.feed == nil ? "" : "，以下是上次讀到的資料"), systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("thermo-gateway-error")
            }
            if gateway.feed == nil && gateway.error == nil {
                HStack {
                    ProgressView()
                    Text("讀取中…").foregroundStyle(.secondary)
                }
            } else if gateway.feed != nil && gateway.feed?.sensors.isEmpty == true {
                Text("這個閘道還沒聽到任何溫濕度計。").foregroundStyle(.secondary)
            }
            ForEach(visible) { sensor in
                row(gateway, sensor)
            }
        } header: {
            HStack {
                Text(gateway.title)
                Spacer()
                if let feed = gateway.feed {
                    Text("\(feed.sensors.count) 顆")
                }
            }
            .textCase(nil)
            .accessibilityIdentifier("thermo-gateway-header")
        }
    }

    private func row(_ gateway: ThermoGatewayState, _ sensor: ThermoSensor) -> some View {
        NavigationLink(value: ThermoSensorRef(gateway: gateway.id, sensor: sensor.id)) {
            ThermoRow(sensor: sensor, name: model.displayName(sensor), now: gateway.gatewayNow(phoneNow: Date()) ?? 0)
        }
        .accessibilityIdentifier("thermo-row-\(sensor.id)")
    }
}

struct ThermoRow: View {
    let sensor: ThermoSensor
    let name: String
    let now: Int

    var body: some View {
        let freshness = ThermoFreshness.of(updated: sensor.updated, now: now)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(ThermoText.age(updated: sensor.updated, now: now), systemImage: Self.symbol(freshness))
                        .foregroundStyle(Self.color(freshness))
                    if sensor.battery != nil {
                        Label(ThermoText.battery(sensor.battery), systemImage: ThermoText.batterySymbol(sensor.battery))
                            .foregroundStyle(ThermoText.isBatteryLow(sensor.battery) ? Color.red : Color.secondary)
                    }
                }
                .font(.caption)
                if let error = sensor.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ThermoText.temperature(sensor.temperature))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(freshness == .fresh ? Color.primary : Color.secondary)
                Label(ThermoText.humidity(sensor.humidity), systemImage: "drop.fill")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    static func symbol(_ freshness: ThermoFreshness) -> String {
        switch freshness {
        case .fresh: return "clock"
        case .stale: return "exclamationmark.triangle"
        case .lost: return "exclamationmark.triangle.fill"
        case .never: return "questionmark.circle"
        }
    }

    static func color(_ freshness: ThermoFreshness) -> Color {
        switch freshness {
        case .fresh: return .secondary
        case .stale: return .orange
        case .lost, .never: return .red
        }
    }
}

struct ThermoDetailView: View {
    @ObservedObject var model: ThermoModel
    let ref: ThermoSensorRef
    @State private var nameText = ""

    var body: some View {
        if let found = model.sensor(ref) {
            detail(found.0, found.1)
        } else {
            ContentUnavailableView("找不到這顆溫濕度計", systemImage: "thermometer.medium",
                                   description: Text("閘道這次的資料裡沒有它。"))
        }
    }

    @ViewBuilder
    private func detail(_ gateway: ThermoGatewayState, _ sensor: ThermoSensor) -> some View {
        let now = gateway.gatewayNow(phoneNow: Date()) ?? 0
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(ThermoText.temperature(sensor.temperature))
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Label(ThermoText.humidity(sensor.humidity), systemImage: "drop.fill")
                        .font(.title)
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("thermo-detail-reading")
                HStack {
                    Label(ThermoText.age(updated: sensor.updated, now: now), systemImage: "clock")
                    Spacer()
                    Label("電量 \(ThermoText.battery(sensor.battery))", systemImage: ThermoText.batterySymbol(sensor.battery))
                        .foregroundStyle(ThermoText.isBatteryLow(sensor.battery) ? Color.red : Color.primary)
                        .accessibilityIdentifier("thermo-detail-battery")
                }
                .font(.subheadline)
            }
            ThermoHistorySection(model: model, ref: ref)
            Section {
                TextField(sensor.name, text: $nameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { saveName(sensor) }
                    .accessibilityIdentifier("thermo-name-field")
                Button("儲存名稱") { saveName(sensor) }
                    .disabled(nameText.trimmingCharacters(in: .whitespaces) == (model.preferences.names[sensor.id] ?? ""))
                    .accessibilityIdentifier("thermo-name-save")
            } header: {
                Text("名稱")
            } footer: {
                Text("名稱只存在這支手機。留空會用閘道上的名稱「\(sensor.name)」。")
            }
            Section("狀態") {
                LabeledContent("最後更新", value: ThermoText.age(updated: sensor.updated, now: now))
                LabeledContent("電池", value: ThermoText.battery(sensor.battery))
                LabeledContent("電壓", value: ThermoText.voltage(sensor.voltage))
                LabeledContent("訊號", value: ThermoText.rssi(sensor.rssi))
                LabeledContent("讀取方式", value: ThermoText.format(sensor.format))
                LabeledContent("閘道", value: gateway.title)
                LabeledContent("裝置位址", value: sensor.id)
                if let error = sensor.error {
                    LabeledContent("錯誤", value: error).foregroundStyle(.red)
                }
            }
            Section {
                Toggle("在列表中隱藏", isOn: Binding(
                    get: { model.preferences.hidden.contains(sensor.id) },
                    set: { model.preferences.setHidden(sensor.id, $0) }
                ))
                .accessibilityIdentifier("thermo-hide")
            }
        }
        .navigationTitle(model.displayName(sensor))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nameText = model.preferences.names[sensor.id] ?? "" }
    }

    private func saveName(_ sensor: ThermoSensor) {
        model.preferences.rename(sensor.id, to: nameText)
        nameText = model.preferences.names[sensor.id] ?? ""
    }
}

struct ThermoSettingsView: View {
    @ObservedObject var model: ThermoModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(model: ThermoModel) {
        self.model = model
        _text = State(initialValue: model.gatewayText)
    }

    var body: some View {
        let parsed = ThermoGatewayList.parse(text)
        NavigationStack {
            Form {
                Section {
                    TextField("例如 http://閘道的ZeroTier位址:18787", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("thermo-gateways")
                    ForEach(parsed) { item in
                        switch item.result {
                        case .success(let endpoint):
                            Label(endpoint.sensorsURL.absoluteString, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failure(let error):
                            Label("\(item.line)：\(error.displayText)", systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("閘道網址（一行一個）")
                } footer: {
                    Text("閘道是放在溫濕度計旁、收藍牙廣播的電腦或 ESP32（apps/thermo-ios/pc-gateway）。手機要連上同一個 ZeroTier 網路；網址只存在這支手機。全部留空會顯示示範資料。")
                }
            }
            .navigationTitle("溫濕度閘道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        model.setGatewayText(text)
                        dismiss()
                    }
                    .disabled(parsed.contains { !$0.isValid })
                    .accessibilityIdentifier("thermo-gateways-save")
                }
            }
        }
    }
}
