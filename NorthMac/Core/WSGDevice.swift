import Foundation

/// NS-WSG — a Namco-style 3-voice waveform sound generator, emulated as an
/// Advantage I/O slot card. This is the reference implementation of the
/// NS-WSG v1 register spec (Documentation/NSWSG.md); future hardware (CPLD /
/// RP2040 / TTL rebuild on a real slot card) is to be built to the same spec,
/// so software written against this model runs unchanged on the card.
///
/// Architecture (after the original Pac-Man sound circuit, generalized):
///   - 3 voices, each: 20-bit frequency accumulator, 4-bit volume,
///     one of 8 waveforms
///   - waveform RAM: 8 waveforms x 32 samples x 4 bits (RAM, not PROM —
///     software uploads its own waveforms)
///   - accumulators tick at 96 kHz; sample = wave[wsel][acc >> 15]
///
/// Register window (16 ports, slot-decoded by the motherboard; slot 3 in
/// the emulator, ports 0x30-0x3F):
///   +0x0  WTIDX  (W) waveform RAM index, 0-255 (wf*32 + position)
///   +0x1  WTDAT  (W) sample nibble -> waveRAM[WTIDX], then WTIDX++
///   +0x2  CTRL   (W) bit 0 = master enable (0 silences and resets accs)
///   +0x3  STATUS (R) returns 0x57 ('W') — presence check beyond board ID
///   +0x4 + 4v    (W) voice v FLO   freq bits 7:0
///   +0x5 + 4v    (W) voice v FMID  freq bits 15:8
///   +0x6 + 4v    (W) voice v FHI   freq bits 19:16 (low nibble)
///   +0x7 + 4v    (W) voice v VW    bits 3:0 volume, bits 6:4 waveform
///
/// Board ID (port 0x73/0x7B): 0xA5. Tone frequency = freq * 96000 / 2^20 Hz
/// (~0.0916 Hz per LSB; A440 = 4806).
final class WSGDevice {
    static let boardID: UInt8 = 0xA5
    static let statusByte: UInt8 = 0x57

    private let lock = NSLock()

    // Register state (emulator thread writes, render thread reads under lock)
    private var waveRAM = [UInt8](repeating: 0, count: 256)
    private var wtIndex: Int = 0
    private var enabled = false
    private var freq = [UInt32](repeating: 0, count: 3)      // 20-bit
    private var volume = [Int](repeating: 0, count: 3)       // 0-15
    private var waveSel = [Int](repeating: 0, count: 3)      // 0-7

    // Synthesis state (render thread only)
    private var acc = [UInt32](repeating: 0, count: 3)       // 20-bit accumulators
    private var tickCarry: Double = 0.0
    private let tickRate: Double = 96000.0

    /// True when the device could be producing sound — used to keep the
    /// audio engine awake.
    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && (volume[0] | volume[1] | volume[2]) != 0
    }

    // MARK: - Bus interface

    func portOut(_ reg: UInt8, _ data: UInt8) {
        lock.lock(); defer { lock.unlock() }
        switch reg {
        case 0x0:
            wtIndex = Int(data)
        case 0x1:
            waveRAM[wtIndex] = data & 0x0F
            wtIndex = (wtIndex + 1) & 0xFF
        case 0x2:
            enabled = (data & 0x01) != 0
            if !enabled { acc = [0, 0, 0] }
        case 0x4...0xF:
            let v = Int(reg - 4) / 4
            switch (reg - 4) & 3 {
            case 0: freq[v] = (freq[v] & 0xFFF00) | UInt32(data)
            case 1: freq[v] = (freq[v] & 0xF00FF) | (UInt32(data) << 8)
            case 2: freq[v] = (freq[v] & 0x0FFFF) | (UInt32(data & 0x0F) << 16)
            default:
                volume[v] = Int(data & 0x0F)
                waveSel[v] = Int((data >> 4) & 0x07)
            }
        default:
            break
        }
    }

    func portIn(_ reg: UInt8) -> UInt8 {
        reg == 0x3 ? Self.statusByte : 0xFF
    }

    // MARK: - Synthesis

    /// Mix `frames` samples into `data` at `sampleRate`. Called from the
    /// audio render thread (AudioSystem source node).
    func renderAdd(into data: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) {
        lock.lock()
        let en = enabled
        let f = freq, vol = volume, ws = waveSel
        let wave = waveRAM
        lock.unlock()
        guard en, (vol[0] | vol[1] | vol[2]) != 0 else { return }

        let ticksPerSample = tickRate / sampleRate
        for i in 0..<frames {
            tickCarry += ticksPerSample
            let ticks = Int(tickCarry)
            tickCarry -= Double(ticks)
            var mix: Float = 0.0
            for v in 0..<3 where vol[v] != 0 && f[v] != 0 {
                acc[v] = (acc[v] &+ f[v] &* UInt32(ticks)) & 0xFFFFF
                let nib = wave[(ws[v] << 5) | Int(acc[v] >> 15)]
                // center the 4-bit sample and scale by volume
                mix += (Float(nib) - 7.5) / 7.5 * (Float(vol[v]) / 15.0)
            }
            data[i] += mix * 0.28   // headroom for 3 voices + speaker
        }
    }
}
