import CoreBluetooth
import simd

// MARK: - Polar H10 BLE Profile Constants

enum PolarH10Profile {

    // MARK: Service UUIDs

    /// Polar Measurement Data (PMD) service — ECG + ACC
    static let pmdService    = CBUUID(string: "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8")
    /// Standard BLE Heart Rate service
    static let heartRateService = CBUUID(string: "0000180D-0000-1000-8000-00805F9B34FB")
    /// Standard BLE Battery service
    static let batteryService   = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")

    // MARK: Characteristic UUIDs

    /// PMD Control Point — write commands to start/stop ECG and ACC streams
    static let pmdControl  = CBUUID(string: "FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8")
    /// PMD Data — notifications carrying multiplexed ECG and ACC frames
    static let pmdData     = CBUUID(string: "FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8")
    /// Standard Heart Rate Measurement — BPM + optional RR intervals
    static let hrMeasurement = CBUUID(string: "00002A37-0000-1000-8000-00805F9B34FB")
    /// Standard Battery Level — 0–100 %
    static let batteryLevel  = CBUUID(string: "00002A19-0000-1000-8000-00805F9B34FB")

    // MARK: PMD Op Codes

    static let opStop:       UInt8 = 0x01   // STOP_MEASUREMENT
    static let opStart:      UInt8 = 0x02   // REQUEST_MEASUREMENT_START
    static let opGetSettings:UInt8 = 0x03   // GET_MEASUREMENT_SETTINGS

    // MARK: PMD Measurement Types

    static let typeECGMeas: UInt8 = 0x00
    static let typeACCMeas: UInt8 = 0x02

    // MARK: PMD Control Commands (fallbacks — normally built from queried settings)

    /// Query available settings — sent before starting a stream
    static let cmdGetECGSettings = Data([opGetSettings, typeECGMeas])
    static let cmdGetACCSettings = Data([opGetSettings, typeACCMeas])

    /// Start ECG stream: 130 Hz, 14-bit resolution (fallback if query fails)
    static let cmdECGStart = Data([opStart, typeECGMeas,
                                   0x00, 0x01, 0x82, 0x00,   // SAMPLE_RATE = 130
                                   0x01, 0x01, 0x0E, 0x00])  // RESOLUTION  = 14
    /// Start ACC stream: 200 Hz, 16-bit, 8G (fallback if query fails)
    static let cmdACCStart = Data([opStart, typeACCMeas,
                                   0x00, 0x01, 0xC8, 0x00,   // SAMPLE_RATE = 200
                                   0x01, 0x01, 0x10, 0x00,   // RESOLUTION  = 16
                                   0x02, 0x01, 0x08, 0x00])  // RANGE       = 8
    /// Stop streams
    static let cmdECGStop  = Data([opStop, typeECGMeas])
    static let cmdACCStop  = Data([opStop, typeACCMeas])

    // MARK: PMD Frame Type Discriminators (first byte of PMD Data notification)

    static let frameECG: UInt8 = 0x00
    static let frameACC: UInt8 = 0x02

    // MARK: Signal Parameters

    /// ECG sample rate (Hz)
    static let ecgSampleRate: Int    = 130
    /// ACC sample rate (Hz)
    static let accSampleRate: Int    = 200
    /// RR interpolation target rate (Hz)
    static let rrResampleRate: Float = 4.0
}

// MARK: - Parsed Data Types

struct ECGFrame {
    /// Nanosecond timestamp from device clock (relative, not UTC)
    let timestampNs: UInt64
    /// ECG sample values in microvolts (µV). 130 Hz → ~13 samples per 100 ms frame.
    let samplesUV: [Int32]
}

struct ACCFrame {
    let timestampNs: UInt64
    /// X, Y, Z acceleration in milli-g (mg)
    let samples: [SIMD3<Int16>]
}

struct HRFrame {
    let bpm: Int
    /// RR intervals in milliseconds. Converted from BLE raw (raw × 1000 / 1024).
    let rrIntervalsMs: [Int]
}

// MARK: - Packet Parsers

extension PolarH10Profile {

    /// Parse a PMD Data notification. Returns either an ECGFrame or ACCFrame, or nil for
    /// unsupported/malformed packets.
    static func parsePMDFrame(_ data: Data) -> Any? {
        guard data.count >= 10 else { return nil }
        let frameType = data[0]
        switch frameType {
        case frameECG: return parseECGFrame(data)
        case frameACC: return parseACCFrame(data)
        default:       return nil
        }
    }

    /// Parse ECG PMD frame.
    /// Layout: [frameType(1)] [timestamp_ns LE(8)] [frameInfo(1)] [samples: 3 bytes each, signed int24 LE]
    static func parseECGFrame(_ data: Data) -> ECGFrame? {
        guard data.count >= 10 else { return nil }
        let tsNs = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 1, as: UInt64.self)
        }.littleEndian

        var samples: [Int32] = []
        var offset = 10
        while offset + 3 <= data.count {
            // Read 3-byte little-endian signed integer (int24)
            let b0 = Int32(data[offset])
            let b1 = Int32(data[offset + 1])
            let b2 = Int32(data[offset + 2])
            var raw = b0 | (b1 << 8) | (b2 << 16)
            // Sign-extend from 24 bits to 32 bits
            if raw & 0x800000 != 0 { raw |= Int32(bitPattern: 0xFF000000) }
            samples.append(raw)
            offset += 3
        }
        guard !samples.isEmpty else { return nil }
        return ECGFrame(timestampNs: tsNs, samplesUV: samples)
    }

    /// Parse ACC PMD frame.
    /// Layout: [frameType(1)] [timestamp_ns LE(8)] [frameInfo(1)] [XYZ: 2 bytes each, signed int16 LE, repeating]
    static func parseACCFrame(_ data: Data) -> ACCFrame? {
        guard data.count >= 10 else { return nil }
        let tsNs = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 1, as: UInt64.self)
        }.littleEndian

        var samples: [SIMD3<Int16>] = []
        var offset = 10
        while offset + 6 <= data.count {
            let x = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset,     as: Int16.self)
            }.littleEndian
            let y = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)
            }.littleEndian
            let z = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset + 4, as: Int16.self)
            }.littleEndian
            samples.append(SIMD3<Int16>(x, y, z))
            offset += 6
        }
        guard !samples.isEmpty else { return nil }
        return ACCFrame(timestampNs: tsNs, samples: samples)
    }

    /// Parse a Heart Rate Measurement GATT notification.
    /// Spec: Bluetooth GATT Assigned Numbers — Heart Rate Measurement Characteristic.
    static func parseHRFrame(_ data: Data) -> HRFrame? {
        guard data.count >= 2 else { return nil }
        let flags = data[0]
        let is16bit = (flags & 0x01) != 0
        let hasRR   = (flags & 0x10) != 0

        let bpm: Int
        var offset: Int
        if is16bit {
            guard data.count >= 3 else { return nil }
            bpm    = Int(UInt16(data[1]) | (UInt16(data[2]) << 8))
            offset = 3
        } else {
            bpm    = Int(data[1])
            offset = 2
        }

        // Energy Expended field (optional, bit 3 of flags)
        if (flags & 0x08) != 0 { offset += 2 }

        var rrMs: [Int] = []
        if hasRR {
            while offset + 1 < data.count {
                let raw = Int(data[offset]) | (Int(data[offset + 1]) << 8)
                // BLE spec: RR value is in units of 1/1024 seconds
                rrMs.append(raw * 1000 / 1024)
                offset += 2
            }
        }
        return HRFrame(bpm: bpm, rrIntervalsMs: rrMs)
    }

    // MARK: - Settings Query Helpers

    /// Parse a GET_MEASUREMENT_SETTINGS response from PMD Control Point.
    ///
    /// Response format: `[0xF0][opGetSettings][measType][status=0x00]`
    /// followed by TLV settings: `[type][count][val_L][val_H]…`
    ///
    /// - Returns: measurement type + dict of settingType → sorted available values, or nil on failure.
    static func parseAvailableSettings(_ data: Data) -> (measType: UInt8, settings: [UInt8: [UInt16]])? {
        guard data.count >= 5,
              data[0] == 0xF0,
              data[1] == opGetSettings,
              data[3] == 0x00          // status SUCCESS
        else { return nil }

        let measType = data[2]
        var settings: [UInt8: [UInt16]] = [:]
        var i = 4
        while i + 1 < data.count {
            let settingType = data[i]
            let count       = Int(data[i + 1])
            i += 2
            var values: [UInt16] = []
            for _ in 0..<count {
                guard i + 1 < data.count else { break }
                let val = UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
                values.append(val)
                i += 2
            }
            if !values.isEmpty { settings[settingType] = values }
        }
        return (measType, settings)
    }

    /// Build a START_MEASUREMENT command from available settings, choosing the max value
    /// for each setting type (mirrors `PmdSetting.maxSettings()` in the official SDK).
    static func buildStartCommand(measurementType: UInt8,
                                  from settings: [UInt8: [UInt16]]) -> Data {
        var cmd = Data([opStart, measurementType])
        for settingType in settings.keys.sorted() {
            guard let maxVal = settings[settingType]?.max() else { continue }
            cmd.append(settingType)
            cmd.append(0x01)                        // 1 selected value
            cmd.append(UInt8(maxVal & 0xFF))
            cmd.append(UInt8(maxVal >> 8))
        }
        return cmd
    }
}
