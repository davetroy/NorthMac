import Foundation

final class FloppyDiskController {
    struct Drive {
        var diskData: Data?
        var sourceURL: URL?
        var dirty: Bool = false
        var fileName: String = ""
        var maxTracks: Int = 35
        var maxSectors: Int = 700

        var trackNum: Int = 0
        var sectorNum: Int = 9
        var side: Int = 0
        var motorOn: Bool = false
        var writeProtect: Bool = true   // opt-in: default to write-protected
        var track0: Bool = true
        var stepDirection: Int = 0  // 0=outward, 1=inward
        var stepPulse: Bool = false
        var stepPulsePrev: Bool = false

        var fdcState: Int = 0
        var fdcStateCounter: Int = 0
        var fdcStateSectorNum: Int = 0x0F

        var sectorMark: Bool = true  // HIGH initially
        var sectorMarkPrev: Bool = true
        var serialData: Bool = false
        var diskReadFlag: Bool = false
        var diskWriteFlag: Bool = false

        var acquireMode: Bool = true  // HIGH
        var acquireModePrev: Bool = true

        var writeTargetSector: Int = 0  // captured when the write flag is armed

        var dataBuffer: [UInt8] = [UInt8](repeating: 0, count: 0x202)
        var bytePtr: Int = 0
        var crcVal: UInt8 = 0
        var bytesToXfer: Int = 0
    }

    var drives: [Drive] = [Drive(), Drive()]
    var currentDisk: Int = 0

    /// Called when port 0x83 IN triggers (boot ROM beep)
    var onBeep: (() -> Void)?

    var floppy: Drive {
        get { drives[currentDisk] }
        set { drives[currentDisk] = newValue }
    }

    // Display-related state (advanced by floppy_state)
    var displayFlagCounter: Int = 200
    var displayFlag: Bool = false
    var cmdAckCounter: Int = 0
    var cmdAck: Bool = false

    func mountDisk(drive: Int, url: URL, data: Data, writeProtect: Bool) {
        guard drive >= 0 && drive < 2 else { return }
        drives[drive].diskData = data
        drives[drive].sourceURL = url
        drives[drive].fileName = url.lastPathComponent
        drives[drive].dirty = false
        drives[drive].maxTracks = 35
        drives[drive].maxSectors = 700
        drives[drive].sectorNum = 9
        drives[drive].writeProtect = writeProtect
        drives[drive].trackNum = 0
        drives[drive].track0 = true
        drives[drive].bytePtr = 0
        drives[drive].crcVal = 0
        drives[drive].stepDirection = 0
        drives[drive].stepPulse = false
        drives[drive].stepPulsePrev = false
    }

    // FDC input ports (0x80-0x83)
    func fdcIn(portLo: UInt8) -> UInt8 {
        let port = portLo & 0x03
        var data: UInt8 = 0xFF

        switch port {
        case 0:
            // Read data byte from sector buffer
            if floppy.bytePtr < floppy.dataBuffer.count {
                data = floppy.dataBuffer[floppy.bytePtr]
            }
            var f = floppy
            f.bytePtr += 1
            if f.bytePtr > 513 {  // 0xFB + 512 data + CRC = 514 reads
                f.diskReadFlag = false
                f.serialData = false
                f.fdcState = 35
            }
            floppy = f

        case 1:
            // Get sync byte, load sector buffer
            // Per ADE: do NOT set serialData or fdcState here.
            // The state machine (state 100) sets serialData via floppy_state().
            data = 0xFB
            storeSectorBuffer()
            var f = floppy
            f.bytesToXfer = 0x200
            floppy = f

        case 2:
            // Clear disk read flag (matches ADE: just clears the flag)
            var f = floppy
            f.diskReadFlag = false
            floppy = f

        case 3:
            // Port 0x83 IN: produce beep sound (boot ROM at 0x80AF does IN A,(83h))
            onBeep?()

        default:
            break
        }
        return data
    }

    // FDC output ports (0x80-0x83)
    func fdcOut(portLo: UInt8, data: UInt8) {
        let port = portLo & 0x03

        switch port {
        case 0:
            // Output data byte to floppy (write)
            var f = floppy
            switch f.fdcState {
            case 200:
                if data == 0xFB {
                    f.fdcState = 210
                }
            case 210:
                f.fdcState = 220
            case 220:
                if f.bytePtr <= 0x200 {
                    f.dataBuffer[f.bytePtr] = data
                    f.bytePtr += 1
                }
                if f.bytePtr > 0x200 {
                    floppy = f
                    writeSectorToDisk()
                    var f2 = floppy
                    f2.diskWriteFlag = false
                    f2.fdcState = 35
                    floppy = f2
                    return
                }
            default:
                break
            }
            floppy = f

        case 1:
            // Load drive control register
            loadDriveControlRegister(data)

        case 2:
            // Set disk read flag
            var f = floppy
            f.diskReadFlag = true
            floppy = f
            drives[0].motorOn = true
            drives[1].motorOn = true

        case 3:
            // Set disk write flag.  Hardware-faithful (manual 3.7.7): software
            // arms the flag within 150us of the sector-mark edge, and the data
            // lands in the sector that begins at that mark.  The state machine
            // bumps the counter at state 20 (mid-mark), so in the pre-increment
            // mark states the target is sectorNum+1; the old unconditional
            // incrementSectorNum() here put hardware-correct writers one
            // sector off.
            var f = floppy
            let preIncrement = (f.fdcState == 15 || f.fdcState == 18)
            f.writeTargetSector = preIncrement ? (f.sectorNum + 1) % 10 : f.sectorNum
            f.diskWriteFlag = true
            f.bytePtr = 0
            f.fdcState = 200
            f.fdcStateCounter = 0
            floppy = f

        default:
            break
        }
    }

    func loadDriveControlRegister(_ data: UInt8) {
        if data & 0x01 != 0 {
            currentDisk = 0
            var f = drives[0]
            f.fdcState = 0
            drives[0] = f
        }
        if data & 0x02 != 0 {
            currentDisk = 1
            var f = drives[1]
            f.fdcState = 0
            drives[1] = f
        }

        var f = floppy
        f.stepDirection = (data & 0x20) != 0 ? 1 : 0

        if data & 0x10 != 0 {
            f.stepPulse = true
        } else {
            f.stepPulse = false
            if f.stepPulsePrev {
                floppy = f
                floppyStep()
                f = floppy
            }
        }
        f.stepPulsePrev = f.stepPulse
        f.side = Int((data & 0x40)) / 0x40
        floppy = f
    }

    func floppyStep() {
        var f = floppy
        guard !f.diskWriteFlag else { return }

        if f.stepDirection == 0 {
            // Stepping outward
            if f.trackNum > 0 {
                f.trackNum -= 1
                if f.trackNum == 0 {
                    f.track0 = true
                }
            }
        } else {
            // Stepping inward
            f.trackNum += 1
            if f.trackNum > f.maxTracks {
                f.trackNum = f.maxTracks
            }
            f.track0 = false
        }
        floppy = f
    }

    func incrementSectorNum() {
        var f = floppy
        f.sectorNum += 1
        f.sectorNum %= 10
        f.fdcStateSectorNum = f.sectorNum
        if f.sectorNum == 9 {
            f.fdcStateSectorNum = 0x0F
        }
        floppy = f
    }

    func startSectorRead() {
        //NSLog("FDC: startSectorRead sector=%d track=%d side=%d", floppy.sectorNum, floppy.trackNum, floppy.side)
        incrementSectorNum()
        var f = floppy
        f.fdcState = 100
        f.fdcStateCounter = 0
        floppy = f
    }

    func storeSectorBuffer() {
        var f = floppy
        guard let diskData = f.diskData else {
            //NSLog("FDC: storeSectorBuffer - no disk data!")
            return
        }

        let storeSectNum: Int
        if f.side != 0 {
            storeSectNum = (((f.maxTracks * 2) - 1) - f.trackNum) * 10 + f.sectorNum
        } else {
            storeSectNum = f.trackNum * 10 + f.sectorNum
        }

        let offset = storeSectNum * 512

        // Buffer layout (matches ade reference):
        // [0] = 0xFB (second sync, discarded by boot ROM's first port 0x80 read)
        // [1..512] = 512 data bytes from disk sector
        // [513] = CRC over [1..512]
        f.dataBuffer[0] = 0xFB

        let start = offset
        let end = min(start + 512, diskData.count)
        if start < diskData.count {
            for i in 0..<min(512, end - start) {
                f.dataBuffer[i + 1] = diskData[start + i]
            }
        }

        // CRC over 512 data bytes [1..512]
        // Boot ROM: discards [0], CRC's [1]+[2]+255*2 from loop = 512 bytes, reads [513] as CRC
        f.crcVal = 0
        for i in 1...512 {
            var k = Int(f.dataBuffer[i]) ^ Int(f.crcVal)
            k += k
            if k & 0x100 != 0 {
                k += 1
            }
            f.crcVal = UInt8(k & 0xFF)
        }
        f.dataBuffer[513] = f.crcVal
//        NSLog("FDC: storeSector t=%d s=%d -> data[0..3]=%02X %02X %02X %02X crc=%02X",
//              f.trackNum, f.sectorNum, f.dataBuffer[0], f.dataBuffer[1], f.dataBuffer[2], f.dataBuffer[3], f.crcVal)
        f.bytePtr = 0
        floppy = f
    }

    func writeSectorToDisk() {
        var f = floppy
        guard f.diskData != nil else { return }
        // Write-protect: silently drop the write but still reset bytePtr so the
        // FDC state machine continues normally (matches behavior of a real WP'd disk).
        guard !f.writeProtect else {
            f.bytePtr = 0
            floppy = f
            return
        }

        let storeSectNum: Int
        if f.side != 0 {
            storeSectNum = (((f.maxTracks * 2) - 1) - f.trackNum) * 10 + f.writeTargetSector
        } else {
            storeSectNum = f.trackNum * 10 + f.writeTargetSector
        }

        let offset = storeSectNum * 512
        var data = f.diskData!
        for i in 0..<512 {
            if offset + i < data.count {
                data[offset + i] = f.dataBuffer[i]
            }
        }
        f.diskData = data
        f.dirty = true
        f.bytePtr = 0
        floppy = f
    }

    // MARK: - Write-back

    /// Flush a single drive's modified image to its source URL if dirty and not write-protected.
    /// On first flush for a given file, creates a one-time `.bak` next to the original.
    /// Atomic: `Data.write(.atomic)` writes via temp file + rename, so a crash mid-flush
    /// leaves the original intact.
    @discardableResult
    func flushIfDirty(drive: Int) -> Bool {
        guard drive >= 0 && drive < drives.count else { return false }
        let f = drives[drive]
        guard f.dirty, !f.writeProtect, let url = f.sourceURL, let data = f.diskData else {
            return false
        }

        // One-time backup: never overwrite an image without a `.bak` next to it.
        // If the backup copy fails, abort the flush — preserving the original is more
        // important than persisting changes.
        let backupURL = url.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                try FileManager.default.copyItem(at: url, to: backupURL)
                NSLog("FDC: created backup at %@", backupURL.path)
            } catch {
                NSLog("FDC: backup failed for %@: %@ — aborting flush",
                      url.path, error.localizedDescription)
                return false
            }
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("FDC: write failed for %@: %@", url.path, error.localizedDescription)
            return false
        }

        drives[drive].dirty = false
        NSLog("FDC: flushed drive %d to %@ (%d bytes)", drive, url.lastPathComponent, data.count)
        return true
    }

    /// Flush both floppy drives. Called from EmulatorCore on app termination.
    func flushAll() {
        for i in 0..<drives.count { _ = flushIfDirty(drive: i) }
    }

    // FDC state machine - called from status register reads
    func floppyState() {
        // Display flag counter
        if displayFlagCounter > 0 {
            displayFlagCounter -= 1
        }
        if displayFlagCounter == 0 {
            displayFlagCounter = 200
            displayFlag = true
        }

        // Command acknowledge counter
        if cmdAckCounter > 0 {
            cmdAckCounter -= 1
            if cmdAckCounter == 0 {
                cmdAck = !cmdAck
            }
        }

        var f = floppy

        switch f.fdcState {
        case 0:
            f.fdcState = 15
            f.sectorMark = true
        case 15:
            f.motorOn = true
            f.sectorMark = true
            f.fdcState = 18
            f.fdcStateCounter = 60
        case 18:
            f.fdcStateCounter -= 1
            if f.fdcStateCounter == 0 {
                f.fdcState = 20
            }
        case 20:
            floppy = f
            incrementSectorNum()
            f = floppy
            f.sectorMark = true
            f.fdcState = 30
            f.fdcStateCounter = 5
        case 30:
            f.fdcStateCounter -= 1
            if f.fdcStateCounter == 0 {
                f.fdcState = 35
            }
        case 35:
            f.sectorMark = false
            f.fdcState = 40
            f.fdcStateCounter = 40
        case 40:
            f.fdcStateCounter -= 1
            if f.fdcStateCounter == 0 {
                f.fdcState = 15
            }
        case 100:
            f.serialData = true
            f.fdcStateCounter = 0
        case 200, 210, 220:
            // Write states - handled in fdcOut
            break
        default:
            f.fdcState = 15
        }

        floppy = f
    }
}
