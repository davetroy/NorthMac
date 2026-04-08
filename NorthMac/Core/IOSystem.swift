import Foundation

/// I/O port dispatch and control registers for the NorthStar Advantage
final class IOSystem {
    weak var emulator: EmulatorCore?

    // I/O control register
    var ioControlReg: Int = 0

    // Keyboard state
    var kbdChar: UInt8 = 0
    var kbdDataFlag: Bool = false
    var kbdInterrupt: Bool = false

    // Display state
    var displayFlag: Bool = false
    var blankDisplay: Bool = false
    var displayInterruptEnabled: Bool = false
    var scanline: UInt8 = 0

    // NMI state
    var nonMaskInterrupt: Bool = true

    // IO interrupt (active low)
    var ioInterrupt: Bool = false

    // Flag set when display interrupt should fire (checked by run loop after z80_step)
    var intPending: Bool = false
    // Tracks whether we already fired INT for the current display flag pulse
    // Reset when displayFlag is cleared (port 0xB0 read), set when INT is generated
    var displayIntFired: Bool = false

    var prefixToggle: Bool = false
    var capsLock: Bool = false
    var fourKeyResetEnableFlag: Bool = false
    var cursorLock: Bool = false
    var autoRepeat: Bool = false

    func portIn(_ port: UInt8) -> UInt8 {
        let pHi = port >> 4
        let pLo = port & 0x0F

        switch pHi {
        case 0x00:
            // Slot 6 — Hard Disk Controller
            if let hdc = emulator?.hdc, hdc.mounted {
                return hdc.hdcIn(port: pLo)
            }
            return 0xFF

        case 0x01...0x05:
            // Slot cards 1-5 - stub
            return 0xFF

        case 0x06:
            // RAM parity - always OK
            return 0x01

        case 0x07:
            // Board ID - return card IDs
            return getBoardId(pLo)

        case 0x08:
            // FDC inputs
            return emulator?.fdc.fdcIn(portLo: pLo) ?? 0xFF

        case 0x09:
            // Scan register - output only
            return 0xAA

        case 0x0A:
            // Memory mapping - output only
            return 0xAA

        case 0x0B:
            // Clear display flag (allows next pulse to generate INT)
            displayFlag = false
            displayIntFired = false
            return 0xAA

        case 0x0C:
            // Clear NMI flag
            return 0xAA

        case 0x0D:
            // Status register 2
            return getStatusReg2()

        case 0x0E:
            // Status register 1
            return getStatusReg1()

        case 0x0F:
            // I/O control register - output only
            return 0xAA

        default:
            return 0xFF
        }
    }

    func portOut(_ port: UInt8, _ data: UInt8) {
        let pHi = port >> 4
        let pLo = port & 0x0F

        switch pHi {
        case 0x00:
            // Slot 6 — Hard Disk Controller
            if let hdc = emulator?.hdc, hdc.mounted {
                hdc.hdcOut(port: pLo, data: data)
            }

        case 0x01...0x05:
            // Slot cards 1-5 - stub
            break

        case 0x06:
            // RAM parity
            ioInterrupt = false
            break

        case 0x07:
            // Board ID - input only
            break

        case 0x08:
            // FDC outputs
            emulator?.fdc.fdcOut(portLo: pLo, data: data)

        case 0x09:
            // Scan register
            scanline = data

        case 0x0A:
            // Memory mapping registers
            emulator?.memory.mapRegisterWrite(reg: Int(pLo), data: data)

        case 0x0B:
            // Clear display flag (allows next pulse to generate INT)
            displayFlag = false
            displayIntFired = false

        case 0x0C:
            // Clear NMI flag
            nonMaskInterrupt = false

        case 0x0D, 0x0E:
            // Status regs - input only, NOP
            break

        case 0x0F:
            // I/O control register
            setIOControlRegister(Int(data))

        default:
            break
        }
    }

    func getBoardId(_ slot: UInt8) -> UInt8 {
        // Board ID mapping: p_lo & 0x07 -> 0=slot6, 1=slot5, 2=slot4, 3=slot3, 4=slot2, 5=slot1
        let slotMap: [Int: UInt8] = [
            0: 0xBF,  // slot 6 = HDC (0xBF) — only when HD mounted
            4: 0xDB,  // slot 2 = PIO (0xDB)
            5: 0xF7,  // slot 1 = SIO (0xF7)
        ]
        let id = Int(slot & 0x07)
        // Only report HDC if a hard disk is mounted
        if id == 0 {
            return (emulator?.hdc.mounted ?? false) ? 0xBF : 0xFF
        }
        return slotMap[id] ?? 0xFF
    }

    func setIOControlRegister(_ ioCtl: Int) {
        let cmd = ioCtl & 0x07
        ioControlReg = cmd

        switch cmd {
        case 0: break // Show sector
        case 1: break // Show character LSBs
        case 2: break // Show character MSBs
        case 3: break // Complement KB MI 4-key-Reset Enable Flag
        case 4: break // Cursor Lock
        case 5:
            // Start disk drive motors
            emulator?.fdc.floppy.motorOn = true
        case 6:
            prefixToggle = true
        case 7:
            if prefixToggle {
                fourKeyResetEnableFlag = !fourKeyResetEnableFlag
            } else {
                capsLock = !capsLock
            }
            prefixToggle = false
        default: break
        }

        // Acquire mode (bit 3)
        if let fdc = emulator?.fdc {
            if ioCtl & 0x08 != 0 {
                var f = fdc.floppy
                f.acquireMode = true
                if !f.acquireModePrev {
                    fdc.floppy = f
                    fdc.startSectorRead()
                    f = fdc.floppy
                }
                f.acquireModePrev = f.acquireMode
                fdc.floppy = f
            } else {
                var f = fdc.floppy
                f.acquireMode = false
                f.acquireModePrev = f.acquireMode
                fdc.floppy = f
            }
        }

        // Bit 4: I/O reset
        // Bit 5: Blank display
        blankDisplay = (ioCtl & 0x20) != 0

        // Bit 6: Speaker data — toggling generates tones
        emulator?.audio.speakerToggle(high: (ioCtl & 0x40) != 0)

        // Bit 7: Enable display interrupt
        displayInterruptEnabled = (ioCtl & 0x80) != 0

        // Set cmd_ack_counter
        emulator?.fdc.cmdAckCounter = 3
    }

    func getStatusReg1() -> UInt8 {
        guard let fdc = emulator?.fdc else { return 0xFF }

        // Advance FDC state machine
        fdc.floppyState()

        // Also sync display flag from FDC
        if fdc.displayFlag {
            displayFlag = true
            fdc.displayFlag = false
        }

        // Flag INT on display flag rising edge only (once per pulse)
        if displayFlag && displayInterruptEnabled && !displayIntFired {
            intPending = true
            displayIntFired = true
        }

        var status: UInt8 = 0

        // Bit 0: Keyboard data available
        if kbdInterrupt || kbdDataFlag {
            status |= 0x01
        }

        // Bit 1: I/O interrupt (active LOW = set bit when no interrupt)
        if !ioInterrupt {
            status |= 0x02
        }

        // Bit 2: Display flag
        if displayFlag {
            status |= 0x04
        }

        // Bit 4: Disk write-protected
        if fdc.floppy.writeProtect {
            status |= 0x10
        }

        // Bit 5: Disk at track 0
        if fdc.floppy.track0 {
            status |= 0x20
        }

        // Bit 6: Sector mark
        if fdc.floppy.diskData == nil {
            status |= 0x40  // No disk = sector mark always high
        } else if fdc.floppy.sectorMark {
            status |= 0x40
        }

        // Bit 7: Disk read serial data ready
        if fdc.floppy.serialData {
            status |= 0x80
        }

        return status
    }

    func getStatusReg2() -> UInt8 {
        guard let fdc = emulator?.fdc else { return 0xFF }

        // Advance FDC state machine
        fdc.floppyState()

        // Sync display flag
        if fdc.displayFlag {
            displayFlag = true
            fdc.displayFlag = false
        }

        // Flag INT on display flag rising edge only (once per pulse)
        if displayFlag && displayInterruptEnabled && !displayIntFired {
            intPending = true
            displayIntFired = true
        }

        // Status register 2 format (from Technical Manual Table 3-10):
        // Bits 0-3: Command-dependent data
        // Bit 4: Auto-Repeat flag
        // Bit 5: Character Overrun flag
        // Bit 6: Keyboard Data Flag (always present)
        // Bit 7: Command Acknowledge (toggles on each I/O control write)

        var status: UInt8 = 0

        // Bits 0-3: command-dependent
        switch ioControlReg {
        case 0, 5:
            if fdc.floppy.motorOn {
                status = UInt8(fdc.floppy.fdcStateSectorNum & 0x0F)
            } else {
                status = 0x0E
            }

        case 1:
            status = kbdChar & 0x0F

        case 2:
            status = kbdChar >> 4
            kbdDataFlag = false
            kbdInterrupt = false

        case 3:
            // Keyboard MI flag in bit 0
            break

        case 4:
            if cursorLock { status |= 1 }

        case 6:
            break

        case 7:
            if prefixToggle {
                if fourKeyResetEnableFlag { status |= 1 }
                prefixToggle = false
            } else {
                if capsLock { status |= 1 }
            }

        default:
            break
        }

        // Bit 4: Auto-Repeat
        if autoRepeat {
            status |= 0x10
        }

        // Bit 5: Character Overrun (not implemented, always 0)

        // Bit 6: Keyboard Data Flag - present for ALL commands
        if kbdDataFlag || kbdInterrupt {
            status |= 0x40
        }

        // Bit 7: Command Acknowledge - toggles on each I/O control write
        if fdc.cmdAck {
            status |= 0x80
        }

        return status
    }

    func keyPress(_ char: UInt8) {
        kbdChar = char
        kbdDataFlag = true
    }
}
