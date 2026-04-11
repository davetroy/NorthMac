import Foundation
import Combine
import AppKit
import CoreGraphics

/// Main emulator orchestrating Z80 CPU, memory, I/O, FDC, and display
final class EmulatorCore: ObservableObject {
    @Published var isRunning = false
    @Published var turboMode = UserDefaults.standard.bool(forKey: "turboMode")

    let memory = MemorySystem()
    let fdc = FloppyDiskController()
    let hdc = HardDiskController()
    let io = IOSystem()
    let display = DisplaySystem()  // holds PhosphorColor
    let audio = AudioSystem()

    private var cpu = z80()
    private var emulatorThread: Thread?
    private var shouldRun = false

    // Instruction counter for FDC state machine pacing
    private var instructionCount: Int = 0
    private let floppyPulse = 0x22  // 34 instructions between FDC advances

    // Performance benchmark: published so UI can display
    @Published var benchmarkMHz: Double = 0.0
    @Published var benchmarkFPS: Double = 0.0

    // Enable verbose logging for MED3C traps and boot diagnostics
    #if DEBUG
    static let debugLogging = false
    #else
    static let debugLogging = false
    #endif

    /// Project root directory, derived from this source file's path at compile time.
    /// Used to locate Resources/, Disk Images/, and Hard Disks/ during development.
    static let projectRoot: URL = {
        // #filePath is .../NorthMac/NorthMac/Core/EmulatorCore.swift
        // Project root is three levels up
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // Core/
            .deletingLastPathComponent()  // NorthMac/
            .deletingLastPathComponent()  // project root
    }()

    init() {
        io.emulator = self
        fdc.onBeep = { [weak self] in self?.audio.beep() }
        setupCPU()
    }

    private func setupCPU() {
        // MUST call z80_init first - it NULLs all callbacks
        z80_init(&cpu)

        // Store self reference in userdata
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        cpu.userdata = selfPtr

        // Direct memory access — bypasses read_byte/write_byte callbacks
        cpu.ram = memory.ram
        cpu.mapping_regs = (
            Int32(memory.mappingRegs[0]),
            Int32(memory.mappingRegs[1]),
            Int32(memory.mappingRegs[2]),
            Int32(memory.mappingRegs[3])
        )
        cpu.use_direct_memory = true

        // Keep callbacks as fallback (not used in direct memory mode for reads/writes)
        cpu.read_byte = { (userdata, addr) -> UInt8 in
            let core = Unmanaged<EmulatorCore>.fromOpaque(userdata!).takeUnretainedValue()
            return core.memory.readByte(addr)
        }

        cpu.write_byte = { (userdata, addr, value) in
            let core = Unmanaged<EmulatorCore>.fromOpaque(userdata!).takeUnretainedValue()
            core.memory.writeByte(addr, value)
        }

        cpu.port_in = { (z80ptr, port) -> UInt8 in
            let core = Unmanaged<EmulatorCore>.fromOpaque(z80ptr!.pointee.userdata!).takeUnretainedValue()
            return core.io.portIn(port)
        }

        cpu.port_out = { (z80ptr, port, value) in
            let core = Unmanaged<EmulatorCore>.fromOpaque(z80ptr!.pointee.userdata!).takeUnretainedValue()
            core.io.portOut(port, value)
        }
    }

    /// Loads boot ROM from the shared cache into this instance's memory.
    @discardableResult
    func loadBootROM() -> Bool {
        guard let romBytes = ResourceCache.shared.bootROMData else {
            return false
        }
        memory.loadBootROM(data: romBytes)
        return true
    }

    func mountDisk(url: URL, drive: Int) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            print("ERROR: Could not load disk image from \(url)")
            return
        }
        fdc.mountDisk(drive: drive, data: data)
        print("Disk mounted on drive \(drive + 1): \(url.lastPathComponent) (\(data.count) bytes)")
    }

    func mountHardDisk(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            print("ERROR: Could not load hard disk image from \(url)")
            return
        }
        hdc.mount(data: data)
        hdc.fileName = url.lastPathComponent
        print("Hard disk mounted: \(url.lastPathComponent) (\(data.count / 1024)K)")
    }

    /// Sync CPU's direct-memory mapping registers from MemorySystem
    func syncMappingRegs() {
        cpu.mapping_regs = (
            Int32(memory.mappingRegs[0]),
            Int32(memory.mappingRegs[1]),
            Int32(memory.mappingRegs[2]),
            Int32(memory.mappingRegs[3])
        )
    }

    private var hasBooted = false

    func start() {
        guard !isRunning else { return }
        shouldRun = true
        isRunning = true

        if !hasBooted {
            // Cold boot: all mapping registers point to PROM (like real hardware)
            memory.mappingRegs[0] = 0x0E * 0x4000
            memory.mappingRegs[1] = 0x0E * 0x4000
            memory.mappingRegs[2] = 0x0E * 0x4000
            memory.mappingRegs[3] = 0x0E * 0x4000
            syncMappingRegs()
            cpu.pc = 0x8000
            hasBooted = true
        }

        // Start emulator thread
        emulatorThread = Thread {
            self.runLoop()
        }
        emulatorThread?.qualityOfService = .userInteractive
        emulatorThread?.start()
    }

    func stop() {
        shouldRun = false
        isRunning = false
    }

    func reset() {
        stop()
        hasBooted = false

        // Wait for thread to finish
        Thread.sleep(forTimeInterval: 0.05)

        // Re-init CPU and restore all state
        z80_init(&cpu)
        setupCPU()

        // Reset memory mappings
        memory.mappingRegs[0] = 8 * 0x4000
        memory.mappingRegs[1] = 9 * 0x4000
        memory.mappingRegs[2] = 0x0E * 0x4000
        memory.mappingRegs[3] = 0 * 0x4000
        syncMappingRegs()
        memory.blankingFlag = 0

        // Clear video RAM (pages 8-9) for clean display on reset
        let videoStart = 0x20000
        let videoEnd = 0x28000
        for i in videoStart..<videoEnd {
            memory.ram[i] = 0
        }

        // Reset I/O
        io.nonMaskInterrupt = true
        io.displayFlag = false
        io.kbdDataFlag = false
        io.kbdInterrupt = false
        io.blankDisplay = false
        io.ioControlReg = 0
        io.intPending = false
        io.displayIntFired = false

        // Reset FDC
        fdc.displayFlagCounter = 200
        fdc.displayFlag = false

        instructionCount = 0
        med3cPollingScanned = false
        med3cPollingAddresses = []
        autoEnterInjected = false
        autoEnterDelay = 0

        start()
    }

    // MED3C trap state: polling addresses discovered during initial boot.
    // The trap fires when F33C==C9 (RET stub before disk's own MED3C is patched in).
    // Once the boot loader patches F33C with C3 (JP), we let Z80 execute natively.
    private var med3cPollingScanned = false
    private var med3cPollingAddresses: [UInt16] = []

    // Auto-inject ENTER key after boot ROM displays "LOAD SYSTEM"
    // (triggered by checking video RAM for the prompt text)
    private var autoEnterInjected = false
    private var autoEnterDelay: Int = 0

    private func runLoop() {
        let cyclesPerFrame: UInt = 4_000_000 / 60  // ~66666 cycles per frame at 4MHz/60fps
        var frameCycles: UInt = 0
        var fdcCounter: Int = 0

        // Benchmark: measure cycles/sec and frames/sec over 1-second windows
        var benchCycleStart = cpu.cyc
        var benchFrameCount: UInt = 0
        var benchStartTime = mach_absolute_time()
        var machTimebaseRatio: Double = 1.0
        do {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            machTimebaseRatio = Double(info.numer) / Double(info.denom)
        }

        while shouldRun {
            // MED3C trap: intercept CALL F33C/F33F when F33C is a RET stub (C9).
            // Once the boot loader patches F33C with C3 (JP to disk's own MED3C),
            // we let the Z80 execute natively — the disk's MED3C handles it.
            let pc = cpu.pc
            if pc == 0xF33C || pc == 0xF33F {
                if memory.readByte(0xF33C) == 0xC9 {
                    if !med3cPollingScanned {
                        // First detection: scan boot loader for polling patterns
                        // while code is still clean (before any DMA writes)
                        med3cPollingScanned = true
                        scanBootLoaderPolling()
                    }
                    handleMED3CTrap()
                    fdcCounter += 1
                    continue
                }
            }

            let cycBefore = cpu.cyc
            z80_step(&cpu)
            frameCycles &+= cpu.cyc &- cycBefore

            // Check interrupt flag (set by port callbacks)
            if io.intPending {
                io.intPending = false
                z80_gen_int(&cpu, 0xFF)
            }

            // Advance FDC state machine every ~34 instructions
            fdcCounter += 1
            if fdcCounter >= floppyPulse {
                fdcCounter = 0
                fdc.floppyState()
                if fdc.displayFlag {
                    io.displayFlag = true
                    fdc.displayFlag = false
                }
                if io.displayFlag && io.displayInterruptEnabled && !io.displayIntFired {
                    z80_gen_int(&cpu, 0xFF)
                    io.displayIntFired = true
                }
            }

            // Frame timing
            if frameCycles >= cyclesPerFrame {
                frameCycles = 0

                // Auto-inject ENTER key for "LOAD SYSTEM" prompt during automated testing
                if !autoEnterInjected {
                    autoEnterDelay += 1
                    if autoEnterDelay > 120 {  // ~2 seconds at 60fps
                        // Check video RAM for "LOAD" text (indicates prompt is displayed)
                        let videoBase = 0x20000
                        let row3start = videoBase + 3 * 80  // check a few rows
                        var hasContent = false
                        for i in 0..<80 {
                            if memory.ram[row3start + i] != 0x00 {
                                hasContent = true
                                break
                            }
                        }
                        if hasContent {
                            io.keyPress(0x0D)  // ENTER key
                            autoEnterInjected = true
                            if Self.debugLogging { NSLog("AUTO: Injected ENTER key for LOAD SYSTEM prompt") }
                        }
                    }
                }


                // Write boot status to /tmp for automated testing (~10s after ENTER)
                if autoEnterInjected && autoEnterDelay == 720 {
                    writeBootStatus()
                }
                autoEnterDelay += 1

                // Benchmark: report every second
                benchFrameCount += 1
                let now = mach_absolute_time()
                let elapsedNs = Double(now - benchStartTime) * machTimebaseRatio
                if elapsedNs >= 1_000_000_000 {
                    let elapsedSec = elapsedNs / 1_000_000_000
                    let cyclesElapsed = cpu.cyc - benchCycleStart
                    let mhz = Double(cyclesElapsed) / elapsedSec / 1_000_000
                    let fps = Double(benchFrameCount) / elapsedSec
                    DispatchQueue.main.async { [weak self] in
                        self?.benchmarkMHz = mhz
                        self?.benchmarkFPS = fps
                    }
                    // Write to file for automated collection
                    let line = String(format: "%.2f MHz, %.1f fps, turbo=%d\n", mhz, fps, turboMode ? 1 : 0)
                    try? line.write(toFile: "/tmp/northmac_benchmark.txt", atomically: true, encoding: .utf8)
                    benchCycleStart = cpu.cyc
                    benchFrameCount = 0
                    benchStartTime = now
                }

                if !turboMode {
                    Thread.sleep(forTimeInterval: 1.0 / 60.0)
                }
            }
        }
    }

    /// Write boot status report to /tmp/northmac_boot_status.txt
    /// Decodes video RAM bitmap rows into rough text for verification
    private func writeBootStatus() {
        var lines: [String] = []
        lines.append("=== NorthMac Boot Status ===")
        lines.append("Disk: \(fdc.drives[0].fileName)")

        // Count non-zero bytes in video RAM
        var nonZero = 0
        for i in 0..<(80 * 256) {
            if memory.ram[0x20000 + i] != 0 { nonZero += 1 }
        }
        lines.append("Video RAM non-zero bytes: \(nonZero)")

        // Dump first 24 text rows (each row = 12 scanlines of 80 bytes)
        // For each row, show which columns have any pixels set
        for row in 0..<24 {
            var rowText = ""
            for col in 0..<80 {
                var colHasPixels = false
                for scanline in 0..<12 {
                    let offset = 0x20000 + (row * 12 + scanline) * 80 + col
                    if offset < 0x20000 + 80 * 256 && memory.ram[offset] != 0 {
                        colHasPixels = true
                        break
                    }
                }
                rowText += colHasPixels ? "#" : " "
            }
            let trimmed = rowText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append(String(format: "Row %2d: |%@|", row, rowText))
            }
        }

        lines.append("MED3C trap active: \(med3cPollingScanned)")
        lines.append("Mapping regs: [\(memory.mappingRegs.map { String(format: "%05X", $0) }.joined(separator: ", "))]")
        lines.append("PC: \(String(format: "%04X", cpu.pc))")

        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(toFile: "/tmp/northmac_boot_status.txt", atomically: true, encoding: .utf8)
        if Self.debugLogging { NSLog("BOOT STATUS: wrote report to /tmp/northmac_boot_status.txt (%d video bytes active)", nonZero) }
    }

    /// Scan boot loader code (F200-F400) for LD A,(nn) / OR A / JP P polling patterns.
    /// Called once on first MED3C detection, before any DMA writes can corrupt the code.
    private func scanBootLoaderPolling() {
        med3cPollingAddresses = []
        var addr: UInt16 = 0xF200
        while addr < 0xF400 {
            if memory.readByte(addr) == 0x3A {  // LD A,(nn)
                let pollLo = memory.readByte(addr &+ 1)
                let pollHi = memory.readByte(addr &+ 2)
                let pollAddr = UInt16(pollHi) << 8 | UInt16(pollLo)
                // Check if OR A (B7) / JP P (F2) follows within 4 bytes
                for offset: UInt16 in 3..<7 {
                    if memory.readByte(addr &+ offset) == 0xB7 &&
                       memory.readByte(addr &+ offset &+ 1) == 0xF2 {
                        if !med3cPollingAddresses.contains(pollAddr) {
                            med3cPollingAddresses.append(pollAddr)
                            if Self.debugLogging { NSLog("MED3C: found polling addr %04X at code %04X", pollAddr, addr) }
                        }
                        break
                    }
                }
            }
            addr = addr &+ 1
        }
        if Self.debugLogging {
            NSLog("MED3C: detected %d polling addresses: %@", med3cPollingAddresses.count,
                  med3cPollingAddresses.map { String(format: "%04X", $0) }.joined(separator: ", "))
        }
    }

    /// MED3C trap: polled sector read performed in Swift instead of Z80 PROM code.
    /// Called when PC=F33C/F33F for N/V-series disks that relied on the system PROM.
    ///
    /// Calling convention (from NorthStar system PROM):
    ///   A  = number of sectors to read
    ///   B  = logical track (for DD double-sided: physical track = B>>1, side = B&1)
    ///   C  = drive control (bit 7 = double density, bits 0-2 = drive number 1-based)
    ///   D  = starting sector number (0-9)
    ///   HL = DMA destination address
    private func handleMED3CTrap() {
        let sectorCount = Int(cpu.a)
        var logicalTrack = Int(cpu.b)
        let driveCtrl = Int(cpu.c)
        var sector = Int(cpu.d)
        var dmaAddr = UInt16(cpu.h) << 8 | UInt16(cpu.l)

        let retLo = memory.readByte(cpu.sp)
        let retHi = memory.readByte(cpu.sp &+ 1)
        let retAddr = UInt16(retHi) << 8 | UInt16(retLo)
        if Self.debugLogging {
            NSLog("MED3C trap: A=%02X B=%02X C=%02X D=%02X HL=%04X ret=%04X",
                  cpu.a, cpu.b, cpu.c, cpu.d, dmaAddr, retAddr)
        }

        let driveNum = driveCtrl & 0x07
        let driveIdx = max(0, driveNum - 1)  // convert to 0-based

        guard driveIdx < fdc.drives.count,
              let diskData = fdc.drives[driveIdx].diskData else {
            cpu.a = 1
            cpu.zf = false
            cpu.nf = false
            cpu.cf = false
            popReturnAddress()
            if Self.debugLogging { NSLog("MED3C trap: no disk in drive %d", driveNum) }
            return
        }

        let maxTracks = fdc.drives[driveIdx].maxTracks
        let isDoubleSided = diskData.count > 175 * 1024

        for i in 0..<sectorCount {
            var physTrack: Int
            var side: Int

            if isDoubleSided {
                physTrack = logicalTrack >> 1
                side = logicalTrack & 1
            } else {
                physTrack = logicalTrack
                side = 0
            }

            if physTrack >= maxTracks { physTrack = maxTracks - 1 }

            let storeSectNum: Int
            if side != 0 {
                storeSectNum = (((maxTracks * 2) - 1) - physTrack) * 10 + sector
            } else {
                storeSectNum = physTrack * 10 + sector
            }

            let offset = storeSectNum * 512

            for j in 0..<512 {
                let byteIdx = offset + j
                let byte: UInt8 = byteIdx < diskData.count ? diskData[byteIdx] : 0xFF
                memory.writeByte(dmaAddr, byte)
                dmaAddr = dmaAddr &+ 1
            }

            if Self.debugLogging {
                NSLog("MED3C trap: %d/%d physTrack=%d side=%d sector=%d offset=0x%X",
                      i + 1, sectorCount, physTrack, side, sector, offset)
            }

            sector += 1
            if sector >= 10 {
                sector = 0
                logicalTrack += 1
            }
        }

        // Set completion flags at all polling addresses found during boot loader scan.
        // These emulate what the interrupt-driven ISR would do on real hardware.
        for pollAddr in med3cPollingAddresses {
            memory.writeByte(pollAddr, 0x80)
        }

        // Also scan around the return address for any NEW polling patterns
        // (handles post-boot BIOS calls that weren't in the original boot loader)
        scanAndSetPolling(from: retAddr, range: 80)

        // Return success: A=0, Z flag set
        cpu.a = 0
        cpu.zf = true
        cpu.nf = false
        cpu.cf = false
        cpu.sf = false
        popReturnAddress()
    }

    /// Scan Z80 code around an address for polling patterns and set completion flags.
    /// Used for dynamic discovery of post-boot polling addresses.
    private func scanAndSetPolling(from startAddr: UInt16, range: UInt16) {
        var addr = startAddr
        let endAddr = startAddr &+ range
        while addr < endAddr {
            if memory.readByte(addr) == 0x3A {
                let pollLo = memory.readByte(addr &+ 1)
                let pollHi = memory.readByte(addr &+ 2)
                let pollAddr = UInt16(pollHi) << 8 | UInt16(pollLo)
                for offset: UInt16 in 3..<7 {
                    if memory.readByte(addr &+ offset) == 0xB7 &&
                       memory.readByte(addr &+ offset &+ 1) == 0xF2 {
                        memory.writeByte(pollAddr, 0x80)
                        if !med3cPollingAddresses.contains(pollAddr) {
                            med3cPollingAddresses.append(pollAddr)
                            if Self.debugLogging { NSLog("MED3C: new polling addr %04X from code %04X", pollAddr, addr) }
                        }
                        break
                    }
                }
            }
            addr = addr &+ 1
        }
    }

    /// Pop return address from Z80 stack and set PC
    private func popReturnAddress() {
        let retLo = memory.readByte(cpu.sp)
        let retHi = memory.readByte(cpu.sp &+ 1)
        cpu.sp = cpu.sp &+ 2
        cpu.pc = UInt16(retHi) << 8 | UInt16(retLo)
    }

    func handleKeyDown(_ event: NSEvent) {
        guard let chars = event.characters else { return }
        if let ascii = KeyboardSystem.mapKey(
            keyCode: event.keyCode,
            characters: chars,
            modifiers: event.modifierFlags
        ) {
            io.keyPress(ascii)
        }
    }
}
