import Foundation
import CoreBluetooth

struct TrainerDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let peripheral: CBPeripheral

    static func == (lhs: TrainerDevice, rhs: TrainerDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class TrainerManager: NSObject, ObservableObject {
    @Published var connectionState = "Bluetooth starting…"
    @Published var discoveredTrainers: [TrainerDevice] = []
    @Published var selectedTrainerID: UUID?
    @Published var isConnected = false
    @Published var controlReady = false
    @Published var powerW = 0
    @Published var power3sW = 0
    @Published var cadenceRPM = 0.0
    @Published var speedKPH = 0.0
    @Published var heartRateBPM = 0
    @Published var discoveredHeartRateDevices: [TrainerDevice] = []
    @Published var selectedHeartRateID: UUID?
    @Published var heartRateConnected = false
    @Published var logText = ""
    @Published var lastGradeString = "-"
    @Published var nativeVirtualGear = 12
    @Published var nativeVirtualShiftReady = false

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var heartRatePeripheral: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var indoorBikeData: CBCharacteristic?
    private var heartRateMeasurement: CBCharacteristic?

    private enum ScanMode { case trainer, heartRate }
    private var scanMode: ScanMode = .trainer
    private var powerSamples: [(date: Date, watts: Int)] = []
    private var zwiftNotifyCharacteristic: CBCharacteristic?
    private var zwiftWriteCharacteristic: CBCharacteristic?
    private var zwiftIndicateCharacteristic: CBCharacteristic?

    private var ftmsControlStarted = false
    private var zwiftHandshakeSent = false
    private var zwiftSequence: UInt32 = 0

    private let ftmsService = CBUUID(string: "1826")
    private let indoorBikeDataUUID = CBUUID(string: "2AD2")
    private let controlPointUUID = CBUUID(string: "2AD9")
    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")

    private let zwiftServiceUUID = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
    private let zwiftNotifyUUID = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")
    private let zwiftWriteUUID = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1")
    private let zwiftIndicateUUID = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1")

    // Wahoo / Zwift virtual shifting ratios, easiest -> hardest.
    private let nativeGearRatios: [UInt32] = [
        7500, 8700, 9900, 11100, 12300, 13800, 15300, 16800,
        18600, 20400, 22200, 24000, 26099, 28200, 30300, 32400,
        34900, 37400, 39900, 42399, 45400, 48400, 51400, 54899
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        scanMode = .trainer
        guard central.state == .poweredOn else {
            addLog("Bluetooth non pronto.")
            return
        }

        discoveredTrainers.removeAll()
        addLog("Scanning FTMS trainers…")
        central.scanForPeripherals(
            withServices: [ftmsService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.central.stopScan()
            self?.addLog("Scan stopped.")
        }
    }

    func startHeartRateScan() {
        scanMode = .heartRate
        guard central.state == .poweredOn else {
            addLog("Bluetooth non pronto.")
            return
        }

        discoveredHeartRateDevices.removeAll()
        addLog("Scanning Bluetooth heart-rate sensors…")
        central.scanForPeripherals(
            withServices: [heartRateServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.central.stopScan()
            self?.addLog("HR scan stopped.")
        }
    }

    func connectSelectedHeartRate() {
        guard let id = selectedHeartRateID,
              let device = discoveredHeartRateDevices.first(where: { $0.id == id }) else {
            addLog("Nessun sensore HR selezionato.")
            return
        }
        central.stopScan()
        heartRatePeripheral = device.peripheral
        device.peripheral.delegate = self
        addLog("Connecting HR sensor \(device.name)…")
        central.connect(device.peripheral)
    }

    func disconnectHeartRate() {
        if let peripheral = heartRatePeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func connectSelected() {
        guard let id = selectedTrainerID,
              let trainer = discoveredTrainers.first(where: { $0.id == id }) else {
            addLog("Nessun trainer selezionato.")
            return
        }

        central.stopScan()
        connectedPeripheral = trainer.peripheral
        trainer.peripheral.delegate = self
        connectionState = "Connecting…"
        addLog("Connecting to \(trainer.name)…")
        central.connect(trainer.peripheral)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func setTargetResistance(_ percent: Double) {
        guard let peripheral = connectedPeripheral,
              let cp = controlPoint else {
            addLog("Trainer/control point non disponibile.")
            return
        }

        let bounded = max(0.0, min(100.0, percent))
        // FTMS Set Target Resistance Level (0x04), resolution 0.1%.
        let encoded = UInt8(max(0, min(200, Int((bounded * 2.0).rounded()))))
        let payload = Data([0x04, encoded])
        peripheral.writeValue(payload, for: cp, type: .withResponse)
        addLog(String(format: "Sent target resistance %.1f%%", bounded))
    }

    func setTargetPower(_ watts: Int) {
        guard let peripheral = connectedPeripheral,
              let cp = controlPoint else {
            addLog("Trainer/control point non disponibile.")
            return
        }

        let bounded = max(0, min(2000, watts))
        var payload = Data([0x05])   // FTMS Set Targeted Power
        let value = Int16(bounded)
        payload.append(contentsOf: bytesLE(value))
        peripheral.writeValue(payload, for: cp, type: .withResponse)
        addLog("Sent target power \(bounded) W")
    }

    func setGrade(_ gradePercent: Double) {
        guard let peripheral = connectedPeripheral,
              let cp = controlPoint else {
            addLog("Trainer/control point non disponibile.")
            return
        }

        let bounded = min(20.0, max(-20.0, gradePercent))

        let wind: Int16 = 0
        let grade: Int16 = Int16((bounded * 100.0).rounded())
        let crr: UInt8 = 40
        let cw: UInt8 = 51

        var payload = Data([0x11])
        payload.append(contentsOf: bytesLE(wind))
        payload.append(contentsOf: bytesLE(grade))
        payload.append(crr)
        payload.append(cw)

        peripheral.writeValue(payload, for: cp, type: .withResponse)
        lastGradeString = String(format: "%.2f%%", bounded)
        addLog("Sent grade \(lastGradeString)")
    }


    func nearestNativeGear(for ratio: Double) -> Int {
        guard ratio > 0 else { return 1 }
        let ratios = nativeGearRatios.map { Double($0) / 10000.0 }
        var best = 0
        var delta = Double.greatestFiniteMagnitude
        for (index, candidate) in ratios.enumerated() {
            let d = abs(candidate - ratio)
            if d < delta { delta = d; best = index }
        }
        return best + 1
    }

    func setVirtualRatio(_ ratio: Double) {
        sendVirtualGear(nearestNativeGear(for: ratio))
    }

    func shiftVirtualEasier() {
        let next = max(1, nativeVirtualGear - 1)
        sendVirtualGear(next)
    }

    func shiftVirtualHarder() {
        let next = min(nativeGearRatios.count, nativeVirtualGear + 1)
        sendVirtualGear(next)
    }

    func sendVirtualGear(_ gear: Int) {
        guard let peripheral = connectedPeripheral,
              let characteristic = zwiftWriteCharacteristic else {
            addLog("Virtual shift control not ready.")
            return
        }

        let clampedGear = max(1, min(nativeGearRatios.count, gear))
        let ratio = nativeGearRatios[clampedGear - 1]

        // FreeWheel Shift / Wahoo protocol:
        // 0x3F prefix + protobuf VirtualShiftCommand:
        // field 1 command_type = 1
        // field 2 sequence
        // field 4 nested payload { field 7 gear_ratio }
        var nested = Data([0x38]) // payload.gear_ratio, field 7, varint
        nested.append(contentsOf: encodeVarint(UInt64(ratio)))

        var protobuf = Data([0x08, 0x01, 0x10]) // command_type=1, sequence field
        protobuf.append(contentsOf: encodeVarint(UInt64(zwiftSequence)))
        protobuf.append(0x22) // payload, field 4, length-delimited
        protobuf.append(contentsOf: encodeVarint(UInt64(nested.count)))
        protobuf.append(nested)

        var packet = Data([0x3F])
        packet.append(protobuf)

        peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
        nativeVirtualGear = clampedGear
        zwiftSequence &+= 1

        addLog("Sent native virtual gear \(clampedGear)/24 ratio \(ratio): \(hex(packet))")
    }

    private func sendZwiftHandshakeIfReady() {
        guard !zwiftHandshakeSent,
              let peripheral = connectedPeripheral,
              let characteristic = zwiftWriteCharacteristic,
              zwiftNotifyCharacteristic != nil || zwiftIndicateCharacteristic != nil else {
            return
        }

        let handshake = Data([0x52, 0x69, 0x64, 0x65, 0x4F, 0x6E, 0x02, 0x03]) // RideOn\x02\x03
        peripheral.writeValue(handshake, for: characteristic, type: .withoutResponse)
        zwiftHandshakeSent = true
        nativeVirtualShiftReady = true
        addLog("Sent Zwift RideOn handshake: \(hex(handshake))")
    }

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func requestControl() {
        writeControl(Data([0x00]), label: "Request Control")
    }

    private func startResume() {
        writeControl(Data([0x07]), label: "Start/Resume")
    }

    private func writeControl(_ data: Data, label: String) {
        guard let peripheral = connectedPeripheral,
              let cp = controlPoint else { return }

        peripheral.writeValue(data, for: cp, type: .withResponse)
        addLog("Sent \(label)")
    }

    private func bytesLE<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(message)\n"

        DispatchQueue.main.async {
            self.logText += line
            if self.logText.count > 20_000 {
                self.logText = String(self.logText.suffix(15_000))
            }
        }
    }

    private func parseIndoorBikeData(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }

        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        var i = 2
        func has(_ bit: Int) -> Bool { (flags & (1 << bit)) != 0 }

        var speed: Double?
        var cadence: Double?
        var power: Int?

        func require(_ n: Int) -> Bool { i + n <= bytes.count }

        if !has(0), require(2) {
            let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            speed = Double(raw) / 100.0
            i += 2
        }

        if has(1), require(2) { i += 2 }

        if has(2), require(2) {
            let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            cadence = Double(raw) / 2.0
            i += 2
        }

        if has(3), require(2) { i += 2 }
        if has(4), require(3) { i += 3 }
        if has(5), require(2) { i += 2 }

        if has(6), require(2) {
            let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            power = Int(Int16(bitPattern: raw))
        }

        DispatchQueue.main.async {
            if let speed { self.speedKPH = speed }
            if let cadence { self.cadenceRPM = cadence }
            if let power {
                self.powerW = power
                let now = Date()
                self.powerSamples.append((now, power))
                self.powerSamples.removeAll { now.timeIntervalSince($0.date) > 3.0 }
                if !self.powerSamples.isEmpty {
                    self.power3sW = Int((Double(self.powerSamples.reduce(0) { $0 + $1.watts }) / Double(self.powerSamples.count)).rounded())
                }
            }
        }
    }

    private func parseHeartRate(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let isUInt16 = (bytes[0] & 0x01) != 0
        let bpm: Int
        if isUInt16, bytes.count >= 3 {
            bpm = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        } else {
            bpm = Int(bytes[1])
        }
        DispatchQueue.main.async { self.heartRateBPM = bpm }
    }
}

extension TrainerManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionState = "Bluetooth ready"
            addLog("Bluetooth powered on.")
        case .poweredOff:
            connectionState = "Bluetooth off"
        case .unauthorized:
            connectionState = "Bluetooth unauthorized"
        case .unsupported:
            connectionState = "Bluetooth unsupported"
        default:
            connectionState = "Bluetooth unavailable"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? (scanMode == .heartRate ? "Heart Rate Sensor" : "FTMS Trainer")

        let device = TrainerDevice(id: peripheral.identifier, name: name, peripheral: peripheral)

        if scanMode == .heartRate {
            guard !discoveredHeartRateDevices.contains(where: { $0.id == peripheral.identifier }) else { return }
            discoveredHeartRateDevices.append(device)
            if selectedHeartRateID == nil { selectedHeartRateID = device.id }
            addLog("Found HR: \(name)")
        } else {
            guard !discoveredTrainers.contains(where: { $0.id == peripheral.identifier }) else { return }
            discoveredTrainers.append(device)
            if selectedTrainerID == nil { selectedTrainerID = device.id }
            addLog("Found trainer: \(name)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral.identifier == selectedHeartRateID, peripheral.identifier != selectedTrainerID {
            heartRatePeripheral = peripheral
            peripheral.delegate = self
            heartRateConnected = true
            addLog("HR sensor connected.")
            peripheral.discoverServices([heartRateServiceUUID])
            return
        }

        connectionState = "Connected — discovering FTMS…"
        isConnected = true
        controlReady = false
        ftmsControlStarted = false
        zwiftHandshakeSent = false
        nativeVirtualShiftReady = false
        zwiftSequence = 0
        addLog("Trainer connected.")
        addLog("Discovering ALL BLE services (FTMS + native virtual shift)…")
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = "Connection failed"
        isConnected = false
        controlReady = false
        addLog("Connection failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if peripheral.identifier == heartRatePeripheral?.identifier {
            heartRateConnected = false
            heartRatePeripheral = nil
            heartRateMeasurement = nil
            heartRateBPM = 0
            addLog("HR sensor disconnected.")
            return
        }

        connectionState = "Disconnected"
        isConnected = false
        controlReady = false
        controlPoint = nil
        indoorBikeData = nil
        zwiftNotifyCharacteristic = nil
        zwiftWriteCharacteristic = nil
        zwiftIndicateCharacteristic = nil
        ftmsControlStarted = false
        zwiftHandshakeSent = false
        nativeVirtualShiftReady = false
        addLog("Trainer disconnected.")
    }
}

extension TrainerManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            addLog("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        if peripheral.identifier == heartRatePeripheral?.identifier {
            for service in services where service.uuid == heartRateServiceUUID {
                peripheral.discoverCharacteristics([heartRateMeasurementUUID], for: service)
            }
            return
        }

        for service in services {
            let uuid = service.uuid.uuidString.uppercased()
            if service.uuid == ftmsService {
                addLog("FTMS service found: \(uuid)")
            } else if service.uuid == zwiftServiceUUID {
                addLog("Zwift/Wahoo virtual shift service found: \(uuid)")
            } else {
                addLog("BLE service: \(uuid)")
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            addLog("Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        if peripheral.identifier == heartRatePeripheral?.identifier {
            for characteristic in characteristics where characteristic.uuid == heartRateMeasurementUUID {
                heartRateMeasurement = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("Heart Rate Measurement found.")
            }
            return
        }

        for characteristic in characteristics {
            let serviceUUID = service.uuid.uuidString.uppercased()
            let charUUID = characteristic.uuid.uuidString.uppercased()
            addLog("CHAR service \(serviceUUID): \(charUUID) props=\(characteristic.properties.rawValue)")

            if characteristic.uuid == controlPointUUID {
                controlPoint = characteristic
                addLog("FTMS Control Point found.")
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == indoorBikeDataUUID {
                indoorBikeData = characteristic
                addLog("Indoor Bike Data found.")
                peripheral.setNotifyValue(true, for: characteristic)
            } else if service.uuid == zwiftServiceUUID && characteristic.uuid == zwiftNotifyUUID {
                zwiftNotifyCharacteristic = characteristic
                addLog("Zwift notify characteristic found.")
                peripheral.setNotifyValue(true, for: characteristic)
            } else if service.uuid == zwiftServiceUUID && characteristic.uuid == zwiftWriteUUID {
                zwiftWriteCharacteristic = characteristic
                addLog("Zwift write characteristic found.")
            } else if service.uuid == zwiftServiceUUID && characteristic.uuid == zwiftIndicateUUID {
                zwiftIndicateCharacteristic = characteristic
                addLog("Zwift indicate characteristic found.")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if controlPoint != nil && !ftmsControlStarted {
            ftmsControlStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.requestControl()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.startResume()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.sendZwiftHandshakeIfReady()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            addLog("Notify error: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }

        if characteristic.uuid == heartRateMeasurementUUID {
            parseHeartRate(data)
            return
        }

        if characteristic.uuid == zwiftNotifyUUID || characteristic.uuid == zwiftIndicateUUID {
            addLog("Zwift RX \(characteristic.uuid.uuidString): \(hex(data))")
        }

        if characteristic.uuid == controlPointUUID {
            let bytes = [UInt8](data)

            if bytes.count >= 3, bytes[0] == 0x80 {
                let request = bytes[1]
                let result = bytes[2]

                let resultText: String
                switch result {
                case 0x01: resultText = "Success"
                case 0x02: resultText = "Opcode not supported"
                case 0x03: resultText = "Invalid parameter"
                case 0x04: resultText = "Operation failed"
                case 0x05: resultText = "Control not permitted"
                default: resultText = String(format: "0x%02X", result)
                }

                addLog(String(
                    format: "FTMS response req 0x%02X: %@",
                    request,
                    resultText
                ))

                if request == 0x00, result == 0x01 {
                    DispatchQueue.main.async {
                        self.controlReady = true
                    }
                }
            }
        } else if characteristic.uuid == indoorBikeDataUUID {
            parseIndoorBikeData(data)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            addLog("Write error \(characteristic.uuid): \(error.localizedDescription)")
        }
    }
}