import CoreBluetooth
import Foundation
import WatchLinkCore

/// 在 iPhone 上發佈一個藍牙服務，讓已配對的手錶來要資料。
/// 手錶寫入請求時，系統會把背景中的 App 喚醒約 10 秒，足夠回覆一次。
final class PeripheralService: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    static let serviceUUID = CBUUID(string: "5F2A0001-8C1D-4B6E-9A37-D4E1C0B2A6F3")
    static let rxUUID = CBUUID(string: "5F2A0002-8C1D-4B6E-9A37-D4E1C0B2A6F3")
    static let txUUID = CBUUID(string: "5F2A0003-8C1D-4B6E-9A37-D4E1C0B2A6F3")

    @Published var stateText = "尚未啟動"
    @Published var subscribers = 0
    @Published var lastSync: Date?
    @Published var syncCount = 0

    /// 由 App 提供目前要送給手錶的資料。
    var snapshotProvider: (() async -> Snapshot)?

    private var manager: CBPeripheralManager?
    private var tx: CBMutableCharacteristic?
    private var reassembler = Reassembler()
    private var pending: [Data] = []
    private var chunkSize = 20

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "watchlink.peripheral"]
        )
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            publish(peripheral)
        case .poweredOff:
            stateText = "藍牙未開啟"
        case .unauthorized:
            stateText = "沒有藍牙權限"
        case .unsupported:
            stateText = "此裝置不支援藍牙"
        default:
            stateText = "藍牙準備中"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // 服務一律在藍牙就緒時重新發佈，這裡不需要沿用還原的內容。
    }

    private func publish(_ peripheral: CBPeripheralManager) {
        peripheral.removeAllServices()
        let rx = CBMutableCharacteristic(
            type: Self.rxUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeEncryptionRequired]
        )
        let tx = CBMutableCharacteristic(
            type: Self.txUUID,
            properties: [.notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [rx, tx]
        self.tx = tx
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            stateText = "服務發佈失敗：\(error.localizedDescription)"
            return
        }
        stateText = "等待手錶連線"
        // 保持廣播：App 被系統終止後，這是能再被喚醒的條件之一。
        if !peripheral.isAdvertising {
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        chunkSize = max(20, central.maximumUpdateValueLength)
        subscribers += 1
        stateText = "手錶已連線"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { stateText = "等待手錶連線" }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == Self.rxUUID {
            chunkSize = max(20, request.central.maximumUpdateValueLength)
            if let value = request.value, let message = reassembler.feed(value) {
                handle(message)
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flush()
    }

    // MARK: 訊息

    private func handle(_ message: Data) {
        guard let request = try? JSONDecoder().decode(WatchRequest.self, from: message),
              request.t == "sync", let provider = snapshotProvider else { return }
        Task { @MainActor in
            let snapshot = await provider()
            self.pending.append(contentsOf: Framing.split(snapshot.encoded(), maxChunk: self.chunkSize))
            self.flush()
            self.lastSync = Date()
            self.syncCount += 1
        }
    }

    private func flush() {
        guard let manager, let tx else { return }
        while let next = pending.first {
            if manager.updateValue(next, for: tx, onSubscribedCentrals: nil) {
                pending.removeFirst()
            } else {
                // 佇列滿了，等系統呼叫 peripheralManagerIsReady 再繼續
                return
            }
        }
    }
}
