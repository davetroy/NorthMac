import Foundation

/// NorthStar Advantage memory system: 256KB physical RAM with bank switching
final class MemorySystem {
    // 256KB physical memory (16 pages x 16KB)
    // Uses a raw pointer buffer instead of [UInt8] to avoid Swift COW races
    // when the emulator thread and main thread access memory concurrently.
    static let ramSize = 256 * 1024
    let ram: UnsafeMutablePointer<UInt8>

    // 4 mapping registers: map logical 16KB pages to physical pages
    // Each stores the base physical address (page * 0x4000)
    var mappingRegs: [Int] = [0, 0, 0, 0]

    // Track which logical pages point to display RAM for blanking
    var blankingFlag: UInt8 = 0

    // Video RAM dirty flag for display refresh
    var videoDirty: Bool = false

    // Boot ROM data (2KB, mirrored)
    var bootROM: [UInt8] = []

    init() {
        ram = .allocate(capacity: MemorySystem.ramSize)
        ram.initialize(repeating: 0, count: MemorySystem.ramSize)

        // Initial mapping registers (from ade_main.c:155-158)
        mappingRegs[0] = 8 * 0x4000   // page 8 = video RAM
        mappingRegs[1] = 9 * 0x4000   // page 9 = video RAM
        mappingRegs[2] = 0x0E * 0x4000 // page 14 = boot PROM
        mappingRegs[3] = 0 * 0x4000    // page 0 = main RAM

    }

    deinit {
        ram.deinitialize(count: MemorySystem.ramSize)
        ram.deallocate()
    }

    func loadBootROM(data: [UInt8]) {
        bootROM = data
        var patched = data

        // Patch: NOP out JP signature check at offset 0x0189-0x018D.
        // The boot ROM checks for JP (0xC3) at the entry point, but some
        // CP/M disks (e.g. N2212_64) start with DI (0xF3) instead.
        // Replace: CP C3H / JP NZ,806BH (5 bytes) with NOPs
        if patched.count > 0x018D {
            patched[0x0189] = 0x00  // NOP (was CP)
            patched[0x018A] = 0x00  // NOP (was C3H)
            patched[0x018B] = 0x00  // NOP (was JP NZ)
            patched[0x018C] = 0x00  // NOP (was 6BH)
            patched[0x018D] = 0x00  // NOP (was 80H)
        }

        // Load boot ROM at physical 0x30000 (page 12), mirror every 2KB across pages 12-15
        let promBase = 0x30000
        let promSize = min(patched.count, 0x800) // 2KB
        for page in 0..<4 {
            let pageBase = promBase + page * 0x4000
            for offset in stride(from: 0, to: 0x4000, by: promSize) {
                for i in 0..<promSize {
                    if pageBase + offset + i < MemorySystem.ramSize {
                        ram[pageBase + offset + i] = patched[i]
                    }
                }
            }
        }
        // Data is now in RAM; release the Swift array
        bootROM = []
    }

    // Translate logical Z80 address to physical address
    @inline(__always)
    func physicalAddress(_ logicalAddr: UInt16) -> Int {
        let page = Int(logicalAddr) >> 14
        return mappingRegs[page] + (Int(logicalAddr) & 0x3FFF)
    }

    @inline(__always)
    func readByte(_ addr: UInt16) -> UInt8 {
        ram[mappingRegs[Int(addr) >> 14] + (Int(addr) & 0x3FFF)]
    }

    @inline(__always)
    func writeByte(_ addr: UInt16, _ value: UInt8) {
        let physical = mappingRegs[Int(addr) >> 14] + (Int(addr) & 0x3FFF)
        // Pages 0-3 (0x00000-0x0FFFF): main RAM — always writable
        // Pages 8-9 (0x20000-0x27FFF): video RAM — writable + dirty flag
        // Everything else: read-only or unused
        if physical < 0x10000 {
            ram[physical] = value
        } else if physical >= 0x20000 && physical < 0x28000 {
            ram[physical] = value
            videoDirty = true
        }
    }

    // Memory mapping register write (port 0xA0-0xA3)
    func mapRegisterWrite(reg: Int, data: UInt8) {
        let regIndex = reg & 0x03
        let bitMask: UInt8 = UInt8(1 << regIndex)

        if (data & 0x80) == 0 {
            // High bit zero = map to RAM page
            let page = Int(data & 0x07)
            mappingRegs[regIndex] = page * 0x4000
            blankingFlag &= ~bitMask
        } else if (data & 0x84) == 0x84 {
            // Boot PROM
            mappingRegs[regIndex] = 0x0E * 0x4000
            blankingFlag &= ~bitMask
        } else if (data & 0x06) == 0 {
            // Display RAM (bit 0 selects page 8 or 9)
            let page = 8 + Int(data & 0x01)
            mappingRegs[regIndex] = page * 0x4000
            blankingFlag |= bitMask
        }
    }
}
