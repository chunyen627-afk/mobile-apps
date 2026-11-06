import SwiftUI
import ThermoCore

// The toolbox's thermometer tab, laid out after Mi Home's thermometer pages: devices by room
// with temperature, humidity and comfort; a device page with the reading, comfort, battery and
// day/week/month history; rename, room and hiding; unit and comfort range in the settings.

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
    @State private var renaming: ThermoSensor?

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
            let notices = model.gatewayNotices
            if !notices.isEmpty {
                Section {
                    ForEach(notices) { notice in
                        Label {
                            Text("\(notice.title)：\(notice.text)")
                        } icon: {
                            if notice.isError {
                                Image(systemName: "wifi.exclamationmark")
                            } else {
                                ProgressView()
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(notice.isError ? Color.red : Color.secondary)
                        .accessibilityIdentifier(notice.isError ? "thermo-gateway-error" : "thermo-gateway-notice")
                    }
                }
            }
            let low = model.lowBatteryRows
            if !low.isEmpty {
                Section {
                    Label("\(low.map { model.displayName($0.sensor) }.joined(separator: "、")) 電量不足，請更換電池",
                          systemImage: "battery.25")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("thermo-low-battery")
                }
            }
            ForEach(model.roomGroups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item.gateway, item.sensor)
                    }
                } header: {
                    Text(group.room)
                        .textCase(nil)
                        .accessibilityIdentifier("thermo-room-header-\(group.room)")
                }
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
                .accessibilityLabel("設定")
                .accessibilityIdentifier("thermo-settings")
            }
        }
        .refreshable { await model.refresh() }
        .thermoRenameAlert(model: model, target: $renaming)
    }

    private func row(_ gateway: ThermoGatewayState, _ sensor: ThermoSensor) -> some View {
        let isHidden = model.preferences.hidden.contains(sensor.id)
        return NavigationLink(value: ThermoSensorRef(gateway: gateway.id, sensor: sensor.id)) {
            ThermoRow(sensor: sensor, name: model.displayName(sensor), now: gateway.gatewayNow(phoneNow: Date()) ?? 0,
                      preferences: model.preferences)
        }
        .accessibilityIdentifier("thermo-row-\(sensor.id)")
        // Long press or swipe left, as in Mi Home's device list.
        .contextMenu {
            Button { renaming = sensor } label: { Label("重新命名", systemImage: "pencil") }
            Button { model.preferences.setHidden(sensor.id, !isHidden) } label: {
                Label(isHidden ? "取消隱藏" : "在列表中隱藏", systemImage: isHidden ? "eye" : "eye.slash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button { renaming = sensor } label: { Label("改名", systemImage: "pencil") }
                .tint(.blue)
                .accessibilityIdentifier("thermo-swipe-rename")
        }
    }
}

struct ThermoRow: View {
    let sensor: ThermoSensor
    let name: String
    let now: Int
    let preferences: ThermoPreferences

    var body: some View {
        let freshness = ThermoFreshness.of(updated: sensor.updated, now: now)
        let comfort = preferences.comfortLevel(sensor)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if comfort != .unknown {
                        Text(comfort.text)
                            .foregroundStyle(comfort.isComfortable ? Color.green : Color.orange)
                    }
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
                Text(preferences.temperature(sensor.temperature))
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
    @State private var renaming: ThermoSensor?

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
        let comfort = model.preferences.comfortLevel(sensor)
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.preferences.temperature(sensor.temperature))
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
                if comfort != .unknown {
                    Label(comfort.text, systemImage: comfort.isComfortable ? "face.smiling" : "exclamationmark.circle")
                        .font(.headline)
                        .foregroundStyle(comfort.isComfortable ? Color.green : Color.orange)
                        .accessibilityIdentifier("thermo-comfort")
                }
                HStack {
                    Label(ThermoText.age(updated: sensor.updated, now: now), systemImage: "clock")
                    Spacer()
                    Label("電量 \(ThermoText.battery(sensor.battery))", systemImage: ThermoText.batterySymbol(sensor.battery))
                        .foregroundStyle(ThermoText.isBatteryLow(sensor.battery) ? Color.red : Color.primary)
                        .accessibilityIdentifier("thermo-detail-battery")
                }
                .font(.subheadline)
                if ThermoText.isBatteryLow(sensor.battery) {
                    Text("電量不足，請更換 CR2032 電池。").font(.footnote).foregroundStyle(.red)
                }
            }
            ThermoHistorySection(model: model, ref: ref)
            Section {
                Button { renaming = sensor } label: {
                    LabeledContent("名稱") {
                        HStack(spacing: 6) {
                            Text(model.displayName(sensor))
                            Image(systemName: "pencil")
                        }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("thermo-rename")
                NavigationLink {
                    ThermoRoomPicker(model: model, sensor: sensor)
                } label: {
                    LabeledContent("房間", value: model.preferences.room(sensor.id) ?? ThermoPreferences.noRoom)
                }
                .accessibilityIdentifier("thermo-room")
                Toggle("在列表中隱藏", isOn: Binding(
                    get: { model.preferences.hidden.contains(sensor.id) },
                    set: { model.preferences.setHidden(sensor.id, $0) }
                ))
                .accessibilityIdentifier("thermo-hide")
            } header: {
                Text("裝置設定")
            } footer: {
                Text("名稱、房間與隱藏只存在這支手機。在列表上長按或往左滑也能改名。")
            }
            Section("裝置資訊") {
                LabeledContent("最後更新", value: ThermoText.age(updated: sensor.updated, now: now))
                LabeledContent("電池", value: ThermoText.battery(sensor.battery))
                LabeledContent("電壓", value: ThermoText.voltage(sensor.voltage))
                LabeledContent("訊號", value: ThermoText.rssi(sensor.rssi))
                LabeledContent("讀取方式", value: ThermoText.format(sensor.format))
                LabeledContent("閘道", value: gateway.title)
                    .accessibilityIdentifier("thermo-detail-gateway")
                LabeledContent("裝置位址", value: sensor.id)
                if let error = sensor.error {
                    LabeledContent("錯誤", value: error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(model.displayName(sensor))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { renaming = sensor } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("重新命名")
            }
        }
        .thermoRenameAlert(model: model, target: $renaming)
    }
}

/// Choose the thermometer's room: no room, Mi Home's usual rooms and every room in use, or a new one.
struct ThermoRoomPicker: View {
    @ObservedObject var model: ThermoModel
    let sensor: ThermoSensor
    @Environment(\.dismiss) private var dismiss
    @State private var newRoom = ""

    var body: some View {
        let current = model.preferences.room(sensor.id)
        List {
            Section {
                choice(ThermoPreferences.noRoom, selected: current == nil) {
                    model.preferences.setRoom(sensor.id, nil)
                }
                ForEach(model.roomChoices, id: \.self) { room in
                    choice(room, selected: current == room) {
                        model.preferences.setRoom(sensor.id, room)
                    }
                }
            }
            Section("新增房間") {
                HStack {
                    TextField("房間名稱", text: $newRoom)
                        .accessibilityIdentifier("thermo-new-room")
                    Button("加入") {
                        model.preferences.setRoom(sensor.id, newRoom)
                        dismiss()
                    }
                    .disabled(newRoom.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("thermo-add-room")
                }
            }
        }
        .navigationTitle("房間")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ room: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(room)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("thermo-room-\(room)")
    }
}

extension View {
    /// The rename dialog, as in Mi Home: it opens with the current name; an empty name, or the
    /// gateway's own, goes back to the gateway's name.
    func thermoRenameAlert(model: ThermoModel, target: Binding<ThermoSensor?>) -> some View {
        modifier(ThermoRenameAlert(model: model, target: target))
    }
}

struct ThermoRenameAlert: ViewModifier {
    @ObservedObject var model: ThermoModel
    @Binding var target: ThermoSensor?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("重新命名", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                TextField("名稱", text: $text)
                    .accessibilityIdentifier("thermo-rename-field")
                Button("取消", role: .cancel) { target = nil }
                Button("儲存") {
                    if let sensor = target {
                        model.preferences.rename(sensor, to: text)
                    }
                    target = nil
                }
                .accessibilityIdentifier("thermo-rename-save")
            } message: {
                Text("留空會用閘道上的名稱「\(target?.name ?? "")」。")
            }
            .onChange(of: target?.id) { _, _ in
                if let sensor = target {
                    text = model.displayName(sensor)
                }
            }
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
                Section("溫度單位") {
                    Picker("溫度單位", selection: Binding(
                        get: { model.preferences.fahrenheit },
                        set: { model.preferences.fahrenheit = $0 }
                    )) {
                        Text("攝氏 °C").tag(false)
                        Text("華氏 °F").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("thermo-unit")
                }
                Section {
                    comfortStepper("溫度下限", value: \.temperatureLow, range: 0...40, step: 1, unit: "°C")
                    comfortStepper("溫度上限", value: \.temperatureHigh, range: 1...45, step: 1, unit: "°C")
                    comfortStepper("濕度下限", value: \.humidityLow, range: 0...95, step: 5, unit: "%")
                    comfortStepper("濕度上限", value: \.humidityHigh, range: 5...100, step: 5, unit: "%")
                    Button("恢復預設") { model.preferences.comfort = .standard }
                } header: {
                    Text("舒適度範圍")
                } footer: {
                    Text("範圍內顯示「舒適」，超出顯示偏冷／偏熱、乾燥／潮濕。")
                }
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
            .navigationTitle("溫濕度設定")
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

    private func comfortStepper(_ title: String, value: WritableKeyPath<ThermoComfortZone, Double>,
                                range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        Stepper(value: Binding(
            get: { model.preferences.comfort[keyPath: value] },
            set: {
                var zone = model.preferences.comfort
                zone[keyPath: value] = $0
                zone.normalize()
                model.preferences.comfort = zone
            }
        ), in: range, step: step) {
            LabeledContent(title, value: String(format: "%.0f%@", model.preferences.comfort[keyPath: value], unit))
        }
    }
}
