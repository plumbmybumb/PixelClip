#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

/// `DoorbellRadio` on CoreBluetooth. The central is created lazily (`activate()`), because creating
/// it is what shows iOS's Bluetooth permission prompt; callbacks arrive on the main queue.
/// Scans for the doorbell service (the clip puts it in its advertising packet; the `PixelClip-` name
/// comes in the scan response), only while the app asks: never in the background.
@MainActor
public final class CoreBluetoothRadio: NSObject, DoorbellRadio {
    public var onEvent: ((DoorbellEvent) -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [UUID: (wake: CBCharacteristic, status: CBCharacteristic, info: CBCharacteristic?)] = [:]
    private var pendingWrite: [UUID: UInt8] = [:]
    /// The fast lane of each connected peripheral that has the `req`/`rsp` characteristics.
    private var lanes: [UUID: CoreBluetoothFastLaneLink] = [:]

    private let service = CBUUID(string: PixelClipBLE.serviceUUID)
    private let wakeUUID = CBUUID(string: PixelClipBLE.wakeCharacteristicUUID)
    private let statusUUID = CBUUID(string: PixelClipBLE.statusCharacteristicUUID)
    private let infoUUID = CBUUID(string: PixelClipBLE.infoCharacteristicUUID)
    private let reqUUID = CBUUID(string: PixelClipBLE.requestCharacteristicUUID)
    private let rspUUID = CBUUID(string: PixelClipBLE.responseCharacteristicUUID)

    public override init() { super.init() }

    public var authorization: DoorbellAuthorization {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func activate() {
        if let central {
            send(.radio(Self.map(central.state)))
            return
        }
        // No system "turn on Bluetooth" alert: the app explains and falls back to the button.
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    public func scan() {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // The clip advertises only while no central holds it: one already connected to this iPhone (a
        // link iOS keeps up after the app let it go, or the app's own from before) is never heard by a
        // scan. Take it from the system's connected peripherals instead (rssi 0 marks it).
        for p in central.retrieveConnectedPeripherals(withServices: [service]) {
            peripherals[p.identifier] = p
            send(.discovered(id: p.identifier, name: p.name, rssi: 0, serviceUUIDs: [PixelClipBLE.serviceUUID]))
        }
    }

    public func stopScan() {
        guard let central, central.state == .poweredOn, central.isScanning else { return }
        central.stopScan()
    }

    public func connect(_ id: UUID) {
        guard let central, let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            send(.connectFailed(id))
            return
        }
        peripherals[id] = p
        central.connect(p, options: nil)
    }

    public func disconnect(_ id: UUID) {
        guard let central, let p = peripherals[id] else { return }
        central.cancelPeripheralConnection(p)
        characteristics[id] = nil
        pendingWrite[id] = nil
        lanes.removeValue(forKey: id)?.dropped()
    }

    public func fastLaneLink(for id: UUID) -> (any FastLaneLink)? { lanes[id] }

    public func write(_ command: UInt8, to id: UUID) {
        guard let p = peripherals[id], let c = characteristics[id]?.wake else {
            send(.wrote(id, command: command, attError: CBATTError.Code.writeNotPermitted.rawValue))
            return
        }
        pendingWrite[id] = command
        p.writeValue(Data([command]), for: c, type: .withResponse)
    }

    public func subscribeStatus(_ id: UUID) {
        guard let p = peripherals[id], let c = characteristics[id]?.status, c.properties.contains(.notify) else { return }
        p.setNotifyValue(true, for: c)
    }

    public func readStatus(_ id: UUID) {
        guard let p = peripherals[id], let c = characteristics[id]?.status else { return }
        p.readValue(for: c)
    }

    public func readInfo(_ id: UUID) {
        guard let p = peripherals[id], let c = characteristics[id]?.info else { return }
        p.readValue(for: c)
    }

    /// Events go out on the next main-queue turn, never from inside a call into the radio.
    private func send(_ e: DoorbellEvent) {
        Task { @MainActor [weak self] in self?.onEvent?(e) }
    }

    nonisolated static func map(_ s: CBManagerState) -> DoorbellRadioState {
        switch s {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .resetting: .resetting
        default: .unknown
        }
    }

    fileprivate func discovered(_ p: CBPeripheral, name: String?, serviceUUIDs: [String], rssi: Int) {
        let name = name ?? p.name
        // Only remember what might be a clip (a busy room has dozens of peripherals).
        guard PixelClipBLE.matches(name: name, serviceUUIDs: serviceUUIDs) else { return }
        peripherals[p.identifier] = p
        onEvent?(.discovered(id: p.identifier, name: name, rssi: rssi, serviceUUIDs: serviceUUIDs))
    }

    fileprivate func didConnect(_ p: CBPeripheral) {
        p.delegate = self
        onEvent?(.connected(p.identifier))
        p.discoverServices([service])
    }

    fileprivate func didDiscoverServices(_ p: CBPeripheral, error: (any Error)?) {
        guard error == nil, let s = p.services?.first(where: { $0.uuid == service }) else {
            onEvent?(.missingCharacteristics(p.identifier))
            return
        }
        p.discoverCharacteristics([wakeUUID, statusUUID, infoUUID, reqUUID, rspUUID], for: s)
    }

    fileprivate func didDiscoverCharacteristics(_ p: CBPeripheral, service s: CBService, error: (any Error)?) {
        let cs = s.characteristics ?? []
        guard error == nil, let wake = cs.first(where: { $0.uuid == wakeUUID }), let status = cs.first(where: { $0.uuid == statusUUID }) else {
            onEvent?(.missingCharacteristics(p.identifier))
            return
        }
        characteristics[p.identifier] = (wake, status, cs.first { $0.uuid == infoUUID })
        // Firmware with the fast lane (PROTOCOL §3b) also has `req` and `rsp`.
        if let req = cs.first(where: { $0.uuid == reqUUID }), let rsp = cs.first(where: { $0.uuid == rspUUID }) {
            lanes[p.identifier] = CoreBluetoothFastLaneLink(peripheral: p, request: req, response: rsp)
        }
        onEvent?(.ready(p.identifier))
    }

    fileprivate func didUpdateValue(_ p: CBPeripheral, characteristic c: CBCharacteristic, error: (any Error)?) {
        guard error == nil, let value = c.value else { return }
        if c.uuid == rspUUID { lanes[p.identifier]?.notified(value); return }
        if c.uuid == statusUUID { onEvent?(.status(p.identifier, value)) }
        else if c.uuid == infoUUID { onEvent?(.info(p.identifier, value)) }
    }

    fileprivate func didWrite(_ p: CBPeripheral, characteristic c: CBCharacteristic, error: (any Error)?) {
        guard c.uuid == wakeUUID else { return }
        let command = pendingWrite.removeValue(forKey: p.identifier) ?? PixelClipBLE.wakeCommand
        var code: Int?
        if let error {
            // A refused write arrives as an ATT error; the low-battery refusal is application code 0x80.
            let ns = error as NSError
            code = ns.domain == CBATTErrorDomain ? ns.code : CBATTError.Code.unlikelyError.rawValue
        }
        onEvent?(.wrote(p.identifier, command: command, attError: code))
    }

    fileprivate func didUpdateNotificationState(_ p: CBPeripheral, characteristic c: CBCharacteristic, error: (any Error)?) {
        guard c.uuid == rspUUID else { return }
        lanes[p.identifier]?.subscribed(error == nil && c.isNotifying)
    }

    fileprivate func readyToSend(_ p: CBPeripheral) {
        lanes[p.identifier]?.readyToSend()
    }

    fileprivate func didDisconnect(_ p: CBPeripheral) {
        lanes.removeValue(forKey: p.identifier)?.dropped()
        characteristics[p.identifier] = nil
        pendingWrite[p.identifier] = nil
        onEvent?(.disconnected(p.identifier))
    }
}

// CoreBluetooth calls these on the queue given to the central: the main queue.
extension CoreBluetoothRadio: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = Self.map(central.state)
        MainActor.assumeIsolated { onEvent?(.radio(state)) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let uuids = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])).map(\.uuidString)
        MainActor.assumeIsolated { discovered(peripheral, name: name, serviceUUIDs: uuids, rssi: rssi) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { didConnect(peripheral) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { onEvent?(.connectFailed(id)) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated { didDisconnect(peripheral) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated { didDiscoverServices(peripheral, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        MainActor.assumeIsolated { didDiscoverCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated { didUpdateValue(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated { didWrite(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated { didUpdateNotificationState(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { readyToSend(peripheral) }
    }
}
/// The fast lane over one connected peripheral (`req` write without response, `rsp` notify). Frame
/// size = `maximumWriteValueLength(for: .withoutResponse)` (the negotiated ATT MTU − 3); writes are
/// paced on `canSendWriteWithoutResponse` / `peripheralIsReady(toSendWriteWithoutResponse:)`.
@MainActor
final class CoreBluetoothFastLaneLink: FastLaneLink {
    var onEvent: ((FastLaneLinkEvent) -> Void)?
    private let peripheral: CBPeripheral
    private let request: CBCharacteristic
    private let response: CBCharacteristic
    private var gone = false

    init(peripheral: CBPeripheral, request: CBCharacteristic, response: CBCharacteristic) {
        self.peripheral = peripheral; self.request = request; self.response = response
    }

    var maximumWriteLength: Int { max(20, peripheral.maximumWriteValueLength(for: .withoutResponse)) }
    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }
    var isConnected: Bool { !gone && peripheral.state == .connected }
    var isSubscribed: Bool { response.isNotifying }

    func subscribe() {
        if response.isNotifying { post(.subscribed(true)) } else { peripheral.setNotifyValue(true, for: response) }
    }

    func write(_ frame: Data) {
        // The firmware accepts writes with response too; without response is the fast path.
        peripheral.writeValue(frame, for: request, type: request.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
    }

    func notified(_ value: Data) { onEvent?(.notified(value)) }
    func subscribed(_ ok: Bool) { onEvent?(.subscribed(ok)) }
    func readyToSend() { onEvent?(.readyToSend) }

    func dropped() {
        guard !gone else { return }
        gone = true
        post(.disconnected)
    }

    private func post(_ e: FastLaneLinkEvent) {
        Task { @MainActor [weak self] in self?.onEvent?(e) }
    }
}
#endif
