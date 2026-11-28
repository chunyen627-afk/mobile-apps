import SwiftUI
import GoogleMaps

struct TripView: View {
    @ObservedObject var trip: TripController
    @ObservedObject var service: PeripheralService
    @State private var editingKey = false
    @State private var key = ""

    var body: some View {
        VStack(spacing: 12) {
            if !trip.ready || editingKey {
                SecureField("Google Maps Platform API 金鑰", text: $key)
                    .textContentType(.password).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                Button("儲存金鑰") {
                    trip.configure(key)
                    key = ""
                    editingKey = false
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("金鑰需啟用 Navigation SDK for iOS 與 Maps SDK for iOS，儲存在這支 iPhone 的鑰匙圈。").font(.footnote)
            } else {
                DestinationMap(trip: trip)
                if !trip.active {
                    Text("長按地圖選擇目的地").font(.footnote)
                    Picker("交通方式", selection: $trip.walking) {
                        Text("步行").tag(true)
                        Text("開車").tag(false)
                    }.pickerStyle(.segmented)
                    Button("開始導航") { trip.start() }
                        .buttonStyle(.borderedProminent).disabled(trip.destination == nil)
                } else {
                    if let meters = trip.meters { Text("\(meters) 公尺").font(.title2.bold()) }
                    Button("結束導航") { trip.stop() }.buttonStyle(.bordered)
                }
                if service.subscribers == 0 { Text("手錶尚未連上，重連後會顯示目前步驟。").font(.footnote) }
            }
            if !trip.instruction.isEmpty { Text(trip.instruction).multilineTextAlignment(.center) }
        }
        .padding()
        .navigationTitle("導航")
        .toolbar {
            if trip.ready && !trip.active { Button(editingKey ? "取消" : "更換金鑰") { editingKey.toggle(); key = "" } }
        }
    }
}

private struct DestinationMap: UIViewRepresentable {
    @ObservedObject var trip: TripController

    func makeCoordinator() -> Coordinator { Coordinator(trip) }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        let center = trip.destination ?? trip.location.location?.coordinate ??
            CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96)
        options.camera = GMSCameraPosition.camera(withTarget: center, zoom: trip.location.location == nil && trip.destination == nil ? 7 : 15)
        let map = GMSMapView(options: options)
        map.delegate = context.coordinator
        trip.location.requestWhenInUseAuthorization()
        map.isMyLocationEnabled = true
        map.settings.myLocationButton = true
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        if let destination = trip.destination {
            context.coordinator.pin.position = destination
            context.coordinator.pin.map = map
        }
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        let trip: TripController
        let pin = GMSMarker()
        init(_ trip: TripController) { self.trip = trip }
        func mapView(_ mapView: GMSMapView, didLongPressAt coordinate: CLLocationCoordinate2D) {
            if !trip.active { trip.destination = coordinate }
        }
    }
}
