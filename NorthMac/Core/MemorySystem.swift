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

    static let map0Experiment =
        ProcessInfo.processInfo.environment["NORTHMAC_MAP0_EXPERIMENT"] != nil

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
        // Load 2KB ROM into physical pages 12-15 with 8x mirroring inside
        // each 16KB Z80 window, matching how the real PROM appears to the
        // Z80 when mapping register 2 selects bank 14.
        let promBase = 0x30000
        let promSize = 0x800
        for page in 0..<4 {
            let pageBase = promBase + page * 0x4000
            for offset in stride(from: 0, to: 0x4000, by: promSize) {
                for i in 0..<promSize where i < data.count {
                    ram[pageBase + offset + i] = data[i]
                }
            }
        }

        // Install RST vector stubs at low RAM (physical bank 0). These
        // ensure any stray RST instruction in malformed disk code (e.g.
        // a corrupted boot sector) bounces back to the boot ROM via the
        // pushed return address rather than wandering off into garbage.
        for rstVector in [0x0008, 0x0010, 0x0018, 0x0020, 0x0028, 0x0030, 0x0038] {
            ram[rstVector] = 0xC9  // RET
        }
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
            // High bit zero = map to RAM page.
            // EXPERIMENT (May 2026): boot ROM at offset 0x0078 OUTs A=0 to
            // port 0xA3 with comment "set 16k main ram to the last bank".
            // With strict `data & 0x07` decoding A=0 always selects page 0,
            // contradicting the comment. Hypothesis: when the low 3 bits are
            // 0, the register index itself selects the natural page (R0→bank
            // 0, R1→bank 1, R3→bank 3 = "last bank"). For Stephen Troy disks
            // (load_page=0xC1), this puts page 3 RAM at a different physical
            // bank than page 0, avoiding the stack collision that breaks
            // ULTIMAN.
            // The experiment breaks DEMODIAG's bank integrity test (it maps
            // register-index banks for zero writes, so pattern read-back sees
            // the wrong bank). Off by default; set NORTHMAC_MAP0_EXPERIMENT
            // to re-enable while chasing the ULTIMAN stack collision. The
            // real Advantage's zero-write semantics are probeable on hardware.
            var page = Int(data & 0x07)
            if data == 0 && MemorySystem.map0Experiment { page = regIndex }
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
