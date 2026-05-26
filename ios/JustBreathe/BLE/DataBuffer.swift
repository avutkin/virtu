import Foundation
import simd

// MARK: - Circular Buffer

/// Fixed-capacity FIFO that overwrites the oldest element when full.
struct CircularBuffer<T> {
    private var storage: [T]
    private var head: Int = 0   // write index
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int, defaultValue: T) {
        self.capacity = capacity
        self.storage  = [T](repeating: defaultValue, count: capacity)
    }

    mutating func append(_ value: T) {
        storage[head] = value
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    mutating func append(contentsOf values: [T]) {
        for v in values { append(v) }
    }

    /// Returns elements in FIFO order (oldest first).
    func toArray() -> [T] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(storage[0..<count])
        }
        // Wrap-around case
        let start = head % capacity
        return Array(storage[start...]) + Array(storage[..<start])
    }

    /// Most recent `n` elements (or all if count < n).
    func last(_ n: Int) -> [T] {
        let all = toArray()
        return Array(all.suffix(n))
    }

    mutating func clear() {
        head = 0
        count = 0
    }
}

// MARK: - DataBuffer Actor

/// Actor-isolated ring buffers mirroring the Python DataBuffer.
/// All mutations and reads are serialised through the actor executor.
actor DataBuffer {

    // ECG: 130 Hz × 8 s = 1040 samples for metrics; keep 10 s for display
    private var ecgBuf:  CircularBuffer<Float>        = CircularBuffer(capacity: 1300, defaultValue: 0)
    // ACC Z: 200 Hz × 60 s = 12 000 samples (needed for coherence, phase detection)
    private var accZBuf: CircularBuffer<Float>        = CircularBuffer(capacity: 12000, defaultValue: 0)
    // ACC XYZ: keep 60 s for breathing/phase
    private var accXYZBuf: CircularBuffer<SIMD3<Float>> = CircularBuffer(capacity: 12000, defaultValue: .zero)
    // RR intervals: last 1200 beats (~20 min at rest).
    // ULF power (0–0.003 Hz) requires fftLen ≥ 2048, which needs ~600 beats; 1200 gives comfortable headroom.
    private var rrBuf:   CircularBuffer<Int>          = CircularBuffer(capacity: 1200, defaultValue: 0)
    // Instantaneous BPM (for ULF power, logged at 0.5 Hz)
    private var bpmBuf:  CircularBuffer<Float>        = CircularBuffer(capacity: 1800, defaultValue: 0)

    // MARK: Write

    func appendECG(_ samples: [Float]) {
        ecgBuf.append(contentsOf: samples)
    }

    func appendACC(xyz: [SIMD3<Int16>]) {
        for v in xyz {
            let fv = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
            accXYZBuf.append(fv)
            accZBuf.append(fv.z)
        }
    }

    func appendRR(_ intervals: [Int]) {
        for rr in intervals where rr >= 300 && rr <= 2000 {
            rrBuf.append(rr)
        }
    }

    func appendBPM(_ bpm: Float) {
        bpmBuf.append(bpm)
    }

    // MARK: Read — Snapshot

    /// Returns copies of all buffers for off-actor metric computation.
    func snapshot() -> DataSnapshot {
        DataSnapshot(
            ecg:    ecgBuf.toArray(),
            accZ:   accZBuf.toArray(),
            accXYZ: accXYZBuf.toArray(),
            rr:     rrBuf.toArray(),
            bpm:    bpmBuf.toArray()
        )
    }

    /// Last N ECG samples for waveform display.
    func ecgDisplay(samples: Int = 650) -> [Float] {
        ecgBuf.last(samples)
    }

    /// Last N ACC Z samples for breathing waveform display (200 Hz → 3 s = 600 samples).
    func accDisplay(samples: Int = 600) -> [Float] {
        accZBuf.last(samples)
    }

    /// All clean RR intervals as Float (ms), FIFO order — for tachogram display.
    func rrDisplay() -> [Float] {
        rrBuf.toArray().map { Float($0) }
    }

    /// RR interval count (used to check whether metrics are computable).
    var rrCount: Int { rrBuf.count }

    func clear() {
        ecgBuf.clear()
        accZBuf.clear()
        accXYZBuf.clear()
        rrBuf.clear()
        bpmBuf.clear()
    }
}

// MARK: - Snapshot (value type for off-actor processing)

struct DataSnapshot {
    let ecg:    [Float]
    let accZ:   [Float]
    let accXYZ: [SIMD3<Float>]
    let rr:     [Int]
    let bpm:    [Float]
}
