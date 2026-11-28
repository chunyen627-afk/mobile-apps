import CoreLocation
import GoogleMaps
import GoogleNavigation
import SwiftUI

final class TripController: NSObject, ObservableObject, CLLocationManagerDelegate, GMSNavigatorListener {
    private let bridge: PeripheralService
    let location = CLLocationManager()
    private var session: GMSNavigationSession?
    private var tripID: UUID?
    private var running = false
    private var refresh: Timer?
    private var installedKey: String?
    @Published private(set) var ready = false
    @Published private(set) var active = false
    @Published private(set) var instruction = ""
    @Published private(set) var meters: Int?
    @Published var destination: CLLocationCoordinate2D?
    @Published var walking = true
    private var phase = "ended"
    private var arrow = ""

    init(service: PeripheralService) {
        bridge = service
        super.init()
        location.delegate = self
        let key = NavigationKey.load()
        if !key.isEmpty { configure(key) }
    }

    func configure(_ input: String) {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, NavigationKey.save(key) else { instruction = "無法儲存金鑰"; return }
        if let installedKey, installedKey != key {
            ready = false
            instruction = "金鑰已更新，請重新開啟手錶連結。"
            return
        }
        if installedKey == nil {
            guard GMSServices.provideAPIKey(key) else { instruction = "Google 地圖金鑰無法使用"; return }
            installedKey = key
        }
        ready = true
        instruction = ""
    }

    func start() {
        guard ready, !active, destination != nil else { return }
        let id = UUID()
        tripID = id
        active = true
        instruction = "正在準備導航"
        authorize(id)
    }

    private func authorize(_ id: UUID) {
        switch location.authorizationStatus {
        case .notDetermined:
            awaitingPermission = true
            location.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(withTitle: "Google 導航", companyName: "手錶連結") { [weak self] accepted in
                guard let self, self.tripID == id else { return }
                if accepted { self.route(id) } else { self.stop("需要同意 Google 導航條款才能開始") }
            }
        default:
            stop("請在 iPhone 設定允許使用定位")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let id = tripID else { return }
        if [.denied, .restricted].contains(manager.authorizationStatus) { stop("定位權限已關閉"); return }
        if awaitingPermission && manager.authorizationStatus != .notDetermined {
            awaitingPermission = false
            authorize(id)
        }
    }

    private var awaitingPermission = false

    private func route(_ id: UUID) {
        guard let coordinate = destination,
              let point = GMSNavigationWaypoint(location: coordinate, title: "目的地"),
              let newSession = GMSNavigationServices.createNavigationSession() else {
            stop("無法建立導航"); return
        }
        session = newSession
        newSession.travelMode = walking ? .walking : .driving
        newSession.isStarted = true
        guard let navigator = newSession.navigator else { stop("無法啟動 Google 導航"); return }
        newSession.roadSnappedLocationProvider?.allowsBackgroundLocationUpdates = true
        newSession.roadSnappedLocationProvider?.startUpdatingLocation()
        navigator.add(self)
        update("routing", "正在規劃路線")
        refresh = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.send() }
        navigator.setDestinations([point]) { [weak self] status in
            guard let self, self.tripID == id else { return }
            guard status == .OK else {
                self.stop("規劃路線失敗（Google \(status.rawValue)），請檢查定位、網路及金鑰權限。"); return
            }
            self.running = true
            navigator.isGuidanceActive = true
        }
    }

    func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
        guard session?.navigator === navigator, running else { return }
        switch navInfo.navState {
        case .enroute:
            guard let step = navInfo.currentStep else { update("routing", "正在取得下一步"); return }
            let distance = navInfo.distanceToCurrentStepMeters
            let value = distance.isFinite && distance >= 0 && distance < 50_000_000 ? Int(distance.rounded()) : nil
            update("guiding", step.fullInstructionText, Self.symbol(for: step.maneuver), value)
        case .rerouting: update("rerouting", "正在重新規劃路線")
        case .stopped: stop("導航已結束")
        default: update("routing", "等待導航資料")
        }
    }

    func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
        if session?.navigator === navigator { stop("已抵達目的地") }
    }

    func stop(_ text: String = "導航已結束") {
        refresh?.invalidate()
        refresh = nil
        running = false
        awaitingPermission = false
        update("ended", text)
        tripID = nil
        active = false
        session?.navigator?.remove(self)
        session?.navigator?.isGuidanceActive = false
        session?.navigator?.clearDestinations()
        session?.roadSnappedLocationProvider?.stopUpdatingLocation()
        session?.isStarted = false
        session = nil
    }

    private func update(_ state: String, _ text: String, _ symbol: String = "", _ distance: Int? = nil) {
        phase = state
        instruction = text
        arrow = symbol
        meters = distance
        send()
    }

    private func send() {
        guard let tripID else { return }
        var payload: [String: Any] = ["t": "navigation", "trip": tripID.uuidString, "state": phase,
                                      "text": instruction, "arrow": arrow]
        if let meters { payload["meters"] = meters }
        if let data = try? JSONSerialization.data(withJSONObject: payload) { bridge.publishTrip(data) }
    }

    private static func symbol(for maneuver: GMSNavigationManeuver) -> String {
        switch maneuver {
        case .straight, .depart: return "↑"
        case .turnLeft, .turnSharpLeft: return "←"
        case .turnRight, .turnSharpRight: return "→"
        case .turnSlightLeft, .turnKeepLeft, .forkLeft: return "↖"
        case .turnSlightRight, .turnKeepRight, .forkRight: return "↗"
        case .destination, .destinationLeft, .destinationRight: return "⚑"
        default: return ""
        }
    }
}
