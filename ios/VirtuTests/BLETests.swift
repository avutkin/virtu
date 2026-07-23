import XCTest
@testable import Virtu

/// BLE packet parser tests — run on simulator or device.
final class BLETests: XCTestCase {

    // MARK: - ECG packet parsing

    func testECGFrameParsing() {
        // Minimal synthetic ECG PMD frame:
        //   byte 0:   frame type = 0x00 (ECG)
        //   bytes 1–8: timestamp = 12345678 ns LE
        //   byte 9:   frame info (ignored)
        //   bytes 10–12: sample 1 = 1000 µV (0x0003E8 LE)
        //   bytes 13–15: sample 2 = -500 µV (0xFFFF0C LE → sign-extended)
        var data = Data(count: 16)
        data[0] = 0x00   // ECG frame type
        // Timestamp: 12345678 = 0x00BC614E LE
        let ts: UInt64 = 12345678
        withUnsafeBytes(of: ts.littleEndian) { buf in
            data.replaceSubrange(1..<9, with: buf)
        }
        data[9] = 0x00   // frame info
        // Sample 1: 1000 = 0x0003E8 → bytes [0xE8, 0x03, 0x00]
        data[10] = 0xE8; data[11] = 0x03; data[12] = 0x00
        // Sample 2: -500 = 0xFFFF0C → bytes [0x0C, 0xFF, 0xFF]
        data[13] = 0x0C; data[14] = 0xFF; data[15] = 0xFF

        let frame = PolarH10Profile.parseECGFrame(data)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.samplesUV.count, 2)
        XCTAssertEqual(frame?.samplesUV[0],  1000)
        XCTAssertEqual(frame?.samplesUV[1], -500)
        XCTAssertEqual(frame?.timestampNs, 12345678)
    }

    func testHRFrameWithRR() {
        // Heart Rate GATT packet: flags=0x10 (RR present, 8-bit HR)
        // HR = 72 bpm, two RR values: 834 raw = 815 ms, 818 raw = 799 ms
        var data = Data()
        data.append(0x10)   // flags: RR present, 8-bit HR
        data.append(72)     // BPM
        // RR 1: 834 = 0x0342 LE
        data.append(0x42); data.append(0x03)
        // RR 2: 818 = 0x0332 LE
        data.append(0x32); data.append(0x03)

        let frame = PolarH10Profile.parseHRFrame(data)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.bpm, 72)
        XCTAssertEqual(frame?.rrIntervalsMs.count, 2)
        // 834 * 1000 / 1024 = 814
        XCTAssertEqual(frame?.rrIntervalsMs[0], 834 * 1000 / 1024)
    }

    func testACCFrameParsing() {
        var data = Data(count: 22)
        data[0] = 0x02   // ACC frame type
        let ts: UInt64 = 99999
        withUnsafeBytes(of: ts.littleEndian) { buf in data.replaceSubrange(1..<9, with: buf) }
        data[9] = 0x00   // frame info
        // Sample 1: X=100, Y=200, Z=-300 (mg)
        let x: Int16 = 100;  let y: Int16 = 200;  let z: Int16 = -300
        withUnsafeBytes(of: x.littleEndian) { b in data.replaceSubrange(10..<12, with: b) }
        withUnsafeBytes(of: y.littleEndian) { b in data.replaceSubrange(12..<14, with: b) }
        withUnsafeBytes(of: z.littleEndian) { b in data.replaceSubrange(14..<16, with: b) }
        // Sample 2: X=0, Y=0, Z=1000
        let x2: Int16 = 0; let y2: Int16 = 0; let z2: Int16 = 1000
        withUnsafeBytes(of: x2.littleEndian) { b in data.replaceSubrange(16..<18, with: b) }
        withUnsafeBytes(of: y2.littleEndian) { b in data.replaceSubrange(18..<20, with: b) }
        withUnsafeBytes(of: z2.littleEndian) { b in data.replaceSubrange(20..<22, with: b) }

        let frame = PolarH10Profile.parseACCFrame(data)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.samples.count, 2)
        XCTAssertEqual(frame?.samples[0].x, 100)
        XCTAssertEqual(frame?.samples[0].z, -300)
        XCTAssertEqual(frame?.samples[1].z, 1000)
    }

    // MARK: - DataBuffer

    @MainActor
    func testDataBufferArtifactRejection() async {
        let buf = DataBuffer()
        // Append both valid and artifact RR intervals
        await buf.appendRR([800, 200, 800, 2500, 800])   // 200 and 2500 are artifacts
        let snap = await buf.snapshot()
        XCTAssertEqual(snap.rr.count, 3, "Artifacts should be rejected on append")
    }
}
