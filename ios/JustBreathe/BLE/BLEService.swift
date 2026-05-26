import CoreBluetooth
import Combine
import Foundation

// MARK: - BLE Connection State

enum BLEState: Equatable {
    case idle
    case scanning
    case connecting(name: String)
    case connected(name: String)
    case disconnected(reason: String)
    case unauthorized
    case unsupported
}

// MARK: - Discovered Device

struct BLEDevice: Identifiable, Equatable {
    let id:   UUID
    let name: String
    var rssi: Int

    var rssiDots: String {
        switch rssi {
        case (-50)...: return "●●●●"
        case (-65)...: return "●●●○"
        case (-75)...: return "●●○○"
        default:       return "●○○○"
        }
    }

    var rssiLabel: String {
        switch rssi {
        case (-50)...: return "Excellent"
        case (-65)...: return "Good"
        case (-75)...: return "Fair"
        default:       return "Weak"
        }
    }
}

// MARK: - BLEService
//
// State machine:
//   idle ──startScanning──► scanning ──didDiscover──► connecting ──didConnect──► connected
//                                 ◄──timeout(30s)──              ◄──timeout(15s)──
//   connected ──disconnect()──► idle
//   connected ──didDisconnect──► disconnected ──(backoff)──► scanning…

@MainActor
@Observable
final class BLEService: NSObject {

    // MARK: Observable state

    var state:             BLEState    = .idle
    var batteryLevel:      Int?        = nil
    var lastError:         String?     = nil
    var discoveredDevices: [BLEDevice] = []

    /// Human-readable CoreBluetooth central manager state — shown in the BLE sheet for diagnostics.
    var cbStateDescription: String {
        guard let cm = centralManager else { return "BT not initialised" }
        switch cm.state {
        case .poweredOn:      return "Bluetooth ON"
        case .poweredOff:     return "Bluetooth OFF — check Control Centre"
        case .unauthorized:   return "Permission denied — check Settings → Privacy"
        case .unsupported:    return "BT not supported on this device"
        case .resetting:      return "BT resetting…"
        case .unknown:        return "BT state unknown"
        @unknown default:     return "BT state unknown"
        }
    }

    // MARK: Publishers for metric pipeline

    let ecgSubject = PassthroughSubject<[Float], Never>()
    let accSubject = PassthroughSubject<[SIMD3<Int16>], Never>()
    let hrSubject  = PassthroughSubject<HRFrame, Never>()

    // MARK: Private

    private var centralManager:        CBCentralManager!
    private var peripheral:            CBPeripheral?
    private var pmdControl:            CBCharacteristic?
    private var pmdData:               CBCharacteristic?
    private var hrChar:                CBCharacteristic?
    private var battChar:              CBCharacteristic?
    private var peripheralMap:         [UUID: CBPeripheral] = [:]
    private var connectionTimeoutTask: Task<Void, Never>?
    private var scanTimeoutTask:       Task<Void, Never>?
    private var settingsQueryTask:     Task<Void, Never>?
    private var reconnectTask:         Task<Void, Never>?  // cancellable, replaces asyncAfter
    private var watchdogTask:          Task<Void, Never>?  // detects silent drops

    private var ecgSettings: [UInt8: [UInt16]]?
    private var accSettings: [UInt8: [UInt16]]?

    private let bleQueue       = DispatchQueue(label: "com.justbreathe.ble", qos: .userInitiated)
    private let savedDeviceKey = "justbreathe.polar.uuid"
    private var pmdStreamsStarted = false

    // Backoff state — grows 2s → 4s → 8s → 16s → 30s on repeated unexpected disconnects.
    private var reconnectDelay: TimeInterval = 2.0

    // When true, the next didDisconnectPeripheral callback is expected (we triggered it)
    // and should NOT auto-reconnect. Cleared immediately after use.
    private var suppressNextDisconnect = false

    // When true, auto-scan on BT-power-on is skipped (user intentionally disconnected).
    private var userDisconnected = false

    // MARK: Init

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "justbreathe-ble-central"]
        )
    }

    // MARK: - Public API

    /// Start scanning for a Polar H10. Cancels any pending reconnect timers.
    /// Clears the device list so the UI shows fresh results.
    func startScanning() {
        userDisconnected = false       // explicit scan request resets the "stay idle" flag
        print("🔵 BLE: startScanning — central state: \(centralManager.state.rawValue)")

        guard centralManager.state == .poweredOn else {
            // BT not ready yet — set scanning so centralManagerDidUpdateState retries
            state = .scanning
            return
        }

        lastError = nil
        discoveredDevices = []
        peripheralMap = [:]
        connectionTimeoutTask?.cancel()
        scanTimeoutTask?.cancel()
        reconnectTask?.cancel()

        // If a connection is in progress, cancel it first so we start clean.
        if let p = peripheral {
            suppressNextDisconnect = true
            centralManager.cancelPeripheralConnection(p)
        }
        clearConnectionState()
        centralManager.stopScan()

        // ── Step 1: check if H10 is already OS-connected (another app, background restore).
        // This covers the common case where Polar Flow or a previous session holds the connection.
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            PolarH10Profile.heartRateService,
            PolarH10Profile.pmdService,
        ])
        if let p = alreadyConnected.first {
            print("✅ BLE: device already OS-connected — \(p.name ?? "?")")
            peripheralMap[p.identifier] = p
            let name = p.name ?? "Polar H10"
            discoveredDevices = [BLEDevice(id: p.identifier, name: name, rssi: -65)]
            state = .connecting(name: name)
            doConnect(p)
            return
        }

        // ── Step 2: scan.
        // We scan for the Heart Rate Service — the H10 always advertises this UUID
        // (0x180D), so filtering at the hardware level is reliable and avoids the
        // name-based guard in didDiscover that silently drops devices whose name
        // hasn't been cached by iOS yet.
        state = .scanning
        print("🔵 BLE: scanning (HR service filter)…")
        centralManager.scanForPeripherals(
            withServices: [PolarH10Profile.heartRateService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        scanTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard case .scanning = self.state else { return }
            self.centralManager.stopScan()
            self.state = .idle
            self.lastError = "No Polar H10 found (30 s). Make sure it is powered on and nearby."
        }
    }

    func stopScanning() {
        scanTimeoutTask?.cancel()
        centralManager.stopScan()
        if case .scanning = state { state = .idle }
    }

    /// Connect to a device the user tapped in the list.
    func connectToDevice(_ device: BLEDevice) {
        print("🔵 BLE: connectToDevice — '\(device.name)'")
        centralManager.stopScan()
        scanTimeoutTask?.cancel()

        // Prefer the peripheral object captured during scanning over re-retrieval,
        // because retrieved peripherals may have stale state on older iOS.
        let p = peripheralMap[device.id]
               ?? centralManager.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let p else {
            lastError = "\(device.name) is no longer reachable. Tap Scan to try again."
            state = .idle
            return
        }
        state = .connecting(name: device.name)
        doConnect(p)
    }

    /// Intentional user-initiated disconnect. Does not trigger auto-reconnect.
    func disconnect() {
        guard let p = peripheral else { return }
        print("🔵 BLE: user disconnect")
        userDisconnected = true
        suppressNextDisconnect = true
        connectionTimeoutTask?.cancel()
        scanTimeoutTask?.cancel()
        reconnectTask?.cancel()
        settingsQueryTask?.cancel()
        stopPMDStreams()
        centralManager.cancelPeripheralConnection(p)
        clearConnectionState()
        reconnectDelay = 2.0
        state = .idle
    }

    // MARK: - Private helpers

    private func doConnect(_ p: CBPeripheral) {
        print("🔵 BLE: doConnect — '\(p.name ?? "?")'  p.state=\(p.state.rawValue)")
        peripheral = p
        p.delegate = self
        // Reset stream state so startPMDStreams runs fresh after this connection.
        pmdStreamsStarted = false
        ecgSettings = nil
        accSettings = nil
        // NotifyOnDisconnection ensures the app receives didDisconnectPeripheral
        // even when suspended — critical for detecting drops caused by other BT
        // devices connecting to the iPhone.
        centralManager.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard case .connecting = self.state else { return }
            print("⏱️ BLE: connection timed out — falling back to scan")
            // Cancel the pending connect without triggering auto-reconnect.
            self.suppressNextDisconnect = true
            if let p = self.peripheral {
                self.centralManager.cancelPeripheralConnection(p)
            }
            self.clearConnectionState()
            self.reconnectDelay = 2.0   // timeout ≠ dropped connection; reset backoff
            self.lastError = "H10 not responding. Is it powered on and in range?"
            // Restart scan so the device list becomes visible for manual retry.
            self.startScanning()
        }
    }

    private func discoverServices() {
        peripheral?.discoverServices([
            PolarH10Profile.pmdService,
            PolarH10Profile.heartRateService,
            PolarH10Profile.batteryService,
        ])
    }

    private func startPMDStreams() {
        guard let ctrl = pmdControl, let data = pmdData, let p = peripheral else { return }
        guard !pmdStreamsStarted else { return }
        pmdStreamsStarted = true

        p.setNotifyValue(true, for: ctrl)
        p.setNotifyValue(true, for: data)
        // Stop any lingering streams before starting fresh
        p.writeValue(PolarH10Profile.cmdECGStop, for: ctrl, type: .withResponse)
        p.writeValue(PolarH10Profile.cmdACCStop, for: ctrl, type: .withResponse)

        // Query device capabilities; 0.4 s delay lets the stop-writes complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let ctrl = self.pmdControl, let p = self.peripheral else { return }
            print("🔵 BLE: querying ECG settings")
            p.writeValue(PolarH10Profile.cmdGetECGSettings, for: ctrl, type: .withResponse)

            // Fallback: if device doesn't answer the query in 4 s, use hardcoded defaults
            self.settingsQueryTask?.cancel()
            self.settingsQueryTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                print("⚠️ BLE: settings query timed out — using defaults")
                self.launchStreams(ecg: PolarH10Profile.cmdECGStart,
                                   acc: PolarH10Profile.cmdACCStart)
            }
        }
    }

    private func launchStreams(ecg: Data, acc: Data) {
        guard let ctrl = pmdControl, let p = peripheral else { return }
        print("🔵 BLE: starting ECG — \(ecg.hexLog)")
        p.writeValue(ecg, for: ctrl, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let ctrl = self.pmdControl, let p = self.peripheral else { return }
            print("🔵 BLE: starting ACC — \(acc.hexLog)")
            p.writeValue(acc, for: ctrl, type: .withResponse)
        }
    }

    private func stopPMDStreams() {
        guard let ctrl = pmdControl, let data = pmdData, let p = peripheral else { return }
        p.writeValue(PolarH10Profile.cmdECGStop, for: ctrl, type: .withResponse)
        p.writeValue(PolarH10Profile.cmdACCStop, for: ctrl, type: .withResponse)
        p.setNotifyValue(false, for: ctrl)
        p.setNotifyValue(false, for: data)
    }

    /// Zero out all connection-specific state. Does NOT touch `state`, `reconnectDelay`,
    /// or `userDisconnected` — those are managed by the callers.
    /// Clears only GATT state (characteristics, stream flags). Keeps `peripheral` alive
    /// so the caller can attempt a direct reconnect without scanning.
    private func clearCharacteristics() {
        settingsQueryTask?.cancel()
        watchdogTask?.cancel()
        pmdControl        = nil
        pmdData           = nil
        hrChar            = nil
        battChar          = nil
        batteryLevel      = nil
        pmdStreamsStarted  = false
        ecgSettings       = nil
        accSettings       = nil
    }

    /// Full reset including the peripheral reference. Used for intentional
    /// disconnects and fresh scans.
    private func clearConnectionState() {
        clearCharacteristics()
        peripheral = nil
    }

    // MARK: - Watchdog

    /// Starts an 8-second polling loop that checks whether the peripheral
    /// has silently dropped (iOS can discard the connection when another BT
    /// device connects without always delivering didDisconnectPeripheral).
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self else { return }
                guard case .connected = self.state,
                      let p = self.peripheral,
                      p.state != .connected else { continue }
                print("🔴 BLE watchdog: silent disconnect detected — reconnecting")
                self.handleUnexpectedDisconnect(p, error: nil)
            }
        }
    }

    // MARK: - Unexpected disconnect handler

    /// Shared logic for both watchdog-detected and delegate-reported unexpected drops.
    /// Keeps the peripheral reference and attempts a direct reconnect (no scan needed —
    /// iOS will reconnect to the known peripheral as soon as it's available).
    private func handleUnexpectedDisconnect(_ p: CBPeripheral, error: Error?) {
        connectionTimeoutTask?.cancel()
        clearCharacteristics()          // keep `peripheral` for direct reconnect

        let reason = error?.localizedDescription ?? "Disconnected"
        state = .disconnected(reason: reason)

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30.0)
        print("🔵 BLE: reconnecting in \(String(format: "%.1f", delay)) s (direct, no scan)")

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // If the peripheral recovered on its own during the delay, adopt it
            if p.state == .connected {
                print("✅ BLE: peripheral recovered on its own — re-attaching")
                self.peripheral = p
                self.state = .connected(name: p.name ?? "Polar H10")
                self.discoverServices()
                self.startWatchdog()
            } else {
                // Direct connect — no scanning; iOS queues the connect at OS level
                // and completes it when the device becomes available.
                self.peripheral = p
                self.doConnect(p)
            }
        }
    }
}

private extension Data {
    var hexLog: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("🔵 BLE: central state → \(central.state.rawValue)")
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                // Auto-scan on BT power-on, UNLESS the user explicitly disconnected.
                // This prevents surprise reconnects after the user taps Disconnect.
                if !self.userDisconnected {
                    self.startScanning()
                }
            case .unauthorized:
                self.state = .unauthorized
            case .unsupported:
                self.state = .unsupported
            case .poweredOff, .resetting:
                // BT went away — cancel timers, clean up, wait for poweredOn
                self.connectionTimeoutTask?.cancel()
                self.scanTimeoutTask?.cancel()
                self.reconnectTask?.cancel()
                self.clearConnectionState()
                self.state = .disconnected(reason: "Bluetooth is off")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral],
              let p = peripherals.first else { return }
        p.delegate = self
        Task { @MainActor in
            self.peripheralMap[p.identifier] = p
            if p.state == .connected {
                // Already connected — just attach
                self.peripheral = p
                self.pmdStreamsStarted = false
                self.state = .connected(name: p.name ?? "Polar H10")
                self.discoverServices()
            } else {
                // Was connecting — try again via doConnect so timeout is set correctly
                self.state = .connecting(name: p.name ?? "Polar H10")
                self.doConnect(p)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // We scan with a Heart Rate service filter, so every device that reaches
        // this callback IS a heart rate monitor — no name-based guard needed.
        // (Name-based guards silently drop devices whose name hasn't been cached
        // by iOS yet, which happens on first discovery after app install.)
        let name = peripheral.name
                   ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
                   ?? "HR Device"
        let rssiVal = RSSI.intValue
        let uuid    = peripheral.identifier
        print("📡 BLE: found '\(name)' RSSI \(rssiVal) dB  \(uuid)")

        Task { @MainActor in
            self.peripheralMap[uuid] = peripheral

            let device = BLEDevice(id: uuid, name: name.isEmpty ? "Polar H10" : name, rssi: rssiVal)
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == uuid }) {
                self.discoveredDevices[idx] = device
            } else {
                self.discoveredDevices.append(device)
                self.discoveredDevices.sort { $0.rssi > $1.rssi }
            }

            // Auto-connect when the previously-used device is found
            let savedUUID = UserDefaults.standard.string(forKey: self.savedDeviceKey)
            guard uuid.uuidString == savedUUID else { return }
            guard case .scanning = self.state else { return }  // don't interrupt an active connection
            print("✅ BLE: saved device found — auto-connecting")
            self.scanTimeoutTask?.cancel()
            self.centralManager.stopScan()
            self.state = .connecting(name: device.name)
            self.doConnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        print("✅ BLE: connected to '\(peripheral.name ?? "?")'")
        Task { @MainActor in
            self.connectionTimeoutTask?.cancel()
            UserDefaults.standard.set(peripheral.identifier.uuidString,
                                       forKey: self.savedDeviceKey)
            self.reconnectDelay = 2.0   // successful connection resets backoff
            self.state = .connected(name: peripheral.name ?? "Polar H10")
            self.discoverServices()
            self.startWatchdog()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        print("❌ BLE: failed to connect — \(error?.localizedDescription ?? "unknown")")
        Task { @MainActor in
            self.connectionTimeoutTask?.cancel()
            self.clearConnectionState()
            self.reconnectDelay = 2.0
            self.lastError = "Could not connect: \(error?.localizedDescription ?? "unknown error")"
            // Fall back to scan so the user can retry by tapping the device
            self.startScanning()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        print("⚠️ BLE: disconnected — \(error?.localizedDescription ?? "clean")")
        Task { @MainActor in
            // If we triggered this disconnect ourselves (intentional or timeout fallback),
            // the caller already handled state/cleanup — just reset the flag and return.
            if self.suppressNextDisconnect {
                self.suppressNextDisconnect = false
                return
            }
            // Unexpected drop — reconnect directly without scanning.
            self.handleUnexpectedDisconnect(peripheral, error: error)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        if let error { print("❌ BLE: service discovery error — \(error)") }
        Task { @MainActor in
            guard error == nil, let services = peripheral.services else { return }
            for svc in services {
                switch svc.uuid {
                case PolarH10Profile.pmdService:
                    peripheral.discoverCharacteristics(
                        [PolarH10Profile.pmdControl, PolarH10Profile.pmdData], for: svc)
                case PolarH10Profile.heartRateService:
                    peripheral.discoverCharacteristics([PolarH10Profile.hrMeasurement], for: svc)
                case PolarH10Profile.batteryService:
                    peripheral.discoverCharacteristics([PolarH10Profile.batteryLevel], for: svc)
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        if let error { print("❌ BLE: char discovery error — \(error)") }
        Task { @MainActor in
            guard error == nil, let chars = service.characteristics else { return }
            for c in chars {
                switch c.uuid {
                case PolarH10Profile.pmdControl:
                    self.pmdControl = c
                    print("✅ BLE: PMD control char found")
                case PolarH10Profile.pmdData:
                    self.pmdData = c
                    print("✅ BLE: PMD data char found")
                case PolarH10Profile.hrMeasurement:
                    self.hrChar = c
                    peripheral.setNotifyValue(true, for: c)
                    print("✅ BLE: HR measurement subscribed")
                case PolarH10Profile.batteryLevel:
                    self.battChar = c
                    peripheral.readValue(for: c)
                default: break
                }
            }
            // Start PMD streams once both control and data chars are ready.
            // This may fire from the PMD service char discovery callback while
            // HR/Battery discovery is still in flight — that's fine, they're independent.
            if self.pmdControl != nil && self.pmdData != nil {
                print("✅ BLE: both PMD chars ready — starting streams")
                self.startPMDStreams()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        switch characteristic.uuid {

        case PolarH10Profile.pmdData:
            let parsed = PolarH10Profile.parsePMDFrame(data)
            Task { @MainActor in
                if let ecg = parsed as? ECGFrame {
                    self.ecgSubject.send(ecg.samplesUV.map { Float($0) })
                } else if let acc = parsed as? ACCFrame {
                    self.accSubject.send(acc.samples)
                }
            }

        case PolarH10Profile.pmdControl:
            // PMD CP response format: [0xF0][opCode][measType][status][...payload...]
            guard data.count >= 4, data[0] == 0xF0 else { break }
            let opCode   = data[1]
            let measType = data[2]
            let status   = data[3]

            switch opCode {

            case PolarH10Profile.opGetSettings:
                if let parsed = PolarH10Profile.parseAvailableSettings(data) {
                    let tag = parsed.measType == PolarH10Profile.typeECGMeas ? "ECG" : "ACC"
                    print("✅ BLE: \(tag) settings received")
                    Task { @MainActor in
                        if parsed.measType == PolarH10Profile.typeECGMeas {
                            self.ecgSettings = parsed.settings
                            // Chain: query ACC settings next
                            if let ctrl = self.pmdControl, let p = self.peripheral {
                                print("🔵 BLE: querying ACC settings")
                                p.writeValue(PolarH10Profile.cmdGetACCSettings,
                                             for: ctrl, type: .withResponse)
                            }
                        } else if parsed.measType == PolarH10Profile.typeACCMeas {
                            self.accSettings = parsed.settings
                            self.settingsQueryTask?.cancel()
                            let ecgCmd = self.ecgSettings.map {
                                PolarH10Profile.buildStartCommand(
                                    measurementType: PolarH10Profile.typeECGMeas, from: $0)
                            } ?? PolarH10Profile.cmdECGStart
                            let accCmd = PolarH10Profile.buildStartCommand(
                                measurementType: PolarH10Profile.typeACCMeas,
                                from: parsed.settings)
                            self.launchStreams(ecg: ecgCmd, acc: accCmd)
                        }
                    }
                } else {
                    // Device doesn't support the settings query — fall back to hardcoded defaults
                    print("⚠️ BLE: GET_SETTINGS not supported (status=0x\(String(status, radix:16))) — using defaults")
                    Task { @MainActor in
                        self.settingsQueryTask?.cancel()
                        self.launchStreams(ecg: PolarH10Profile.cmdECGStart,
                                           acc: PolarH10Profile.cmdACCStart)
                    }
                }

            case PolarH10Profile.opStart:
                let mt = String(measType, radix: 16, uppercase: true)
                if status == 0x00 {
                    print("✅ BLE: stream start type=0x\(mt) OK")
                } else {
                    let st = String(status, radix: 16, uppercase: true)
                    print("❌ BLE: stream start type=0x\(mt) failed status=0x\(st)")
                    Task { @MainActor in
                        self.lastError = "PMD start error type=0x\(mt) status=0x\(st)"
                    }
                }

            default:
                print("🔵 BLE: PMD response op=0x\(String(opCode, radix:16)) type=0x\(String(measType, radix:16)) status=0x\(String(status, radix:16))")
            }

        case PolarH10Profile.hrMeasurement:
            if let frame = PolarH10Profile.parseHRFrame(data) {
                Task { @MainActor in self.hrSubject.send(frame) }
            }

        case PolarH10Profile.batteryLevel:
            let level = Int(data[0])
            Task { @MainActor in self.batteryLevel = level }

        default: break
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            print("❌ BLE: write error for \(characteristic.uuid) — \(error)")
            Task { @MainActor in
                self.lastError = "BLE write error: \(error.localizedDescription)"
            }
        }
    }
}
