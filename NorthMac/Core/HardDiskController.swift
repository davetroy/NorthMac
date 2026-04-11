import Foundation

/// NorthStar Advantage Hard Disk Controller (HDC)
/// Emulates the 5" hard disk controller board in slot 6 (ports 0x00-0x07)
/// Reference: ade/ade_hdc.c
final class HardDiskController {

    // MARK: - Constants

    static let boardID: UInt8 = 0xBF
    static let sectorsPerTrack = 16
    static let cacheSize = 526      // 10-byte header + 512 data + 4 CRC
    static let headerSize = 10
    static let sectorDataSize = 512

    // State machine values
    private enum State: Int {
        case index0 = 10, index1 = 20, index2 = 30, index3 = 40
        case sector0 = 60, sector1 = 70, sector2 = 80, sector3 = 85, sector4 = 90
        case read0 = 110, read1 = 120, read2 = 130
        case write0 = 160, write1 = 170, write2 = 180
    }

    // MARK: - Disk geometry

    var maxHeads: Int = 0       // 0-based (3 = 4 heads)
    var maxCylinders: Int = 0   // 0-based (152 = 153 cylinders)
    var maxSectors: Int = 0
    var totalSectors: Int = 0

    // MARK: - Controller state

    var diskData: Data?
    private var diskStore: UnsafeMutablePointer<UInt8>?
    private var diskStoreSize: Int = 0
    var fileName: String = ""
    var mounted: Bool { diskData != nil }

    // Sector cache: precomputed headers + data for each sector
    // Stored flat: sectorCache[sectorIndex * cacheSize ..< (sectorIndex+1) * cacheSize]
    private var sectorCachePtr: UnsafeMutablePointer<UInt8>?
    private var sectorCacheSize: Int = 0

    // Cache RAM (1024 bytes) — the HDC's onboard buffer
    var cacheRAM: [UInt8] = [UInt8](repeating: 0, count: 1024)
    var ramPtr: Int = 0

    // Current position
    var cylinder: Int = 0
    var surface: Int = 0
    var sectorNum: Int = 14

    // State machine
    private var state: State = .sector0
    private var stateCounter: Int = 0

    // Status flags
    var sectorFlag: Bool = false
    var indexFlag: Bool = false
    var readWriteActive: Bool = false
    var driveReady: Bool = false
    var driveSelected: Bool = false
    var trackZero: Bool = false
    var seekComplete: Bool = false
    var writeFault: Bool = false

    // Step control
    var stepDirection: Int = 0   // 0=in, 1=out
    var stepPulse: Bool = false
    var stepPulsePrev: Bool = false
    private var seekDelay: Int = 0

    // Write sync
    private var syncOffset: Int = 0

    // MARK: - Mount / Unmount

    deinit {
        freeDiskStore()
        freeSectorCache()
    }

    private func freeDiskStore() {
        if let ptr = diskStore {
            ptr.deinitialize(count: diskStoreSize)
            ptr.deallocate()
            diskStore = nil
            diskStoreSize = 0
        }
    }

    private func freeSectorCache() {
        if let ptr = sectorCachePtr {
            ptr.deinitialize(count: sectorCacheSize)
            ptr.deallocate()
            sectorCachePtr = nil
            sectorCacheSize = 0
        }
    }

    func mount(data: Data) {
        guard data.count >= 128,
              data[0] == 0x00, data[1] == 0xFF else {
            NSLog("HDC: Invalid NHD file (bad magic bytes)")
            return
        }

        diskData = data

        // Copy data into a raw buffer (avoids Swift Array COW overhead)
        freeDiskStore()
        diskStoreSize = data.count
        diskStore = .allocate(capacity: diskStoreSize)
        data.copyBytes(to: diskStore!, count: diskStoreSize)

        // Parse label
        maxSectors = Int(data[39]) + Int(data[40]) * 256
        maxHeads = Int(data[49])
        if maxHeads == 0 { maxHeads = 3 }
        maxCylinders = Int(data[50]) + Int(data[51]) * 256
        if maxCylinders == 0 { maxCylinders = 152 }

        let fileSectors = data.count / Self.sectorDataSize
        totalSectors = max(maxSectors, fileSectors)

        NSLog("HDC: Mounted — %d cyl, %d heads, %d sectors (%dK)",
              maxCylinders + 1, maxHeads + 1, totalSectors, data.count / 1024)

        // Build sector cache (headers + data)
        buildSectorCache()

        // Initialize state
        cylinder = 0
        sectorNum = 14
        state = .sector0
        ramPtr = 0
        trackZero = true
        seekComplete = true
        driveReady = true
        driveSelected = true
        writeFault = false
        sectorFlag = false
        indexFlag = false
        readWriteActive = false
    }

    func unmount() {
        diskData = nil
        freeDiskStore()
        freeSectorCache()
        fileName = ""
        driveReady = false
        driveSelected = false
        seekComplete = false
        trackZero = false
        writeFault = true
    }

    // MARK: - I/O Ports

    /// HDC input (port low nibble 0-7)
    func hdcIn(port: UInt8) -> UInt8 {
        let p = port & 0x07
        guard mounted else { return 0xFF }

        switch p {
        case 0: // Read data byte from cache RAM
            let byte = cacheRAM[ramPtr % cacheRAM.count]
            ramPtr += 1
            return byte

        case 1: // Get HD status (advances state machine)
            advanceState()
            return makeStatus()

        case 2: // Clear RAM pointer
            ramPtr = 0
            return 0

        case 3: // Clear sector flag
            sectorFlag = false
            return 0

        case 4: // Start SYNC (NI)
            return 0

        case 5: // Start READ
            state = .read0
            return 0

        case 6: // Start WRITE
            state = .write0
            syncOffset = 0
            return 0

        case 7: // FORMAT WRITE (NI)
            return 0

        default:
            return 0xFF
        }
    }

    /// HDC output (port low nibble 0-7)
    func hdcOut(port: UInt8, data: UInt8) {
        let p = port & 0x07
        guard mounted else { return }

        switch p {
        case 6: // Load drive control register
            loadDriveControlRegister(data)

        case 7: // Write data byte to cache RAM
            cacheRAM[ramPtr % cacheRAM.count] = data
            if ramPtr == 0 {
                syncOffset = 0
                stateCounter = 1
                state = .write1
            }
            // Look for sync byte (0x01) in range 30-90
            if syncOffset == 0 && ramPtr > 30 && ramPtr < 90 {
                if data == 0x01 {
                    syncOffset = ramPtr
                    readWriteActive = true
                }
            }
            ramPtr += 1

        default:
            break
        }
    }

    // MARK: - Drive Control Register

    private func loadDriveControlRegister(_ data: UInt8) {
        let inverted = ~data
        surface = Int(inverted & 0x03)
        if data & 0x04 != 0 {
            surface = surface | Int(data & 0x04)
        }

        stepDirection = Int((data & 0x20) >> 5)
        let newStepPulse = (data & 0x10) != 0

        // Step on falling edge (HIGH → LOW)
        if !newStepPulse && stepPulsePrev {
            cylinderStep()
        }
        stepPulsePrev = newStepPulse

        // Header read enable (bit 7)
        if data & 0x80 != 0 {
            copyCacheHeader()
        }
    }

    private func cylinderStep() {
        if stepDirection != 0 { // Stepping OUT
            if cylinder > 0 {
                cylinder -= 1
                if cylinder == 0 { trackZero = true }
            }
        } else { // Stepping IN
            cylinder += 1
            if cylinder > maxCylinders { cylinder = maxCylinders }
            trackZero = false
        }
        seekComplete = false
        seekDelay = 2
    }

    // MARK: - Status

    private func makeStatus() -> UInt8 {
        var status: UInt8 = 0
        if sectorFlag          { status |= 0x80 }
        if !indexFlag           { status |= 0x40 }  // active LOW
        if readWriteActive      { status |= 0x20 }
        // bit 4: drive not ready (always ready when mounted)
        if !driveSelected       { status |= 0x08 }
        if !trackZero           { status |= 0x04 }

        if seekDelay > 0 {
            seekDelay -= 1
            seekComplete = seekDelay == 0
        }
        if !seekComplete        { status |= 0x02 }
        if !writeFault          { status |= 0x01 }  // "disk safe" when no fault

        return status
    }

    // MARK: - State Machine

    private func advanceState() {
        switch state {
        // INDEX sequence (sector 0 start of track)
        case .index0:
            indexFlag = true
            copyCacheHeader()
            readWriteActive = false
            state = .index1
            stateCounter = 2

        case .index1:
            stateCounter -= 1
            if stateCounter == 0 {
                indexFlag = false
                sectorFlag = true
                state = .index2
                stateCounter = 2
            }

        case .index2:
            stateCounter -= 1
            if stateCounter == 0 {
                readWriteActive = false
                state = .index3
            }

        case .index3:
            state = .sector1
            stateCounter = 2

        // SECTOR sequence (sectors 1-15)
        case .sector0:
            sectorFlag = true
            readWriteActive = false
            copyCacheHeader()
            stateCounter = 2
            state = .sector1

        case .sector1:
            stateCounter -= 1
            if stateCounter == 0 {
                readWriteActive = false
                state = .sector2
            }

        // READ sequence
        case .read0:
            copyCacheHeader()
            copySectorToRAM()
            stateCounter = 2
            state = .read1

        case .read1:
            stateCounter -= 1
            if stateCounter == 0 {
                readWriteActive = true
                stateCounter = 8
                state = .read2
            }

        case .read2:
            stateCounter -= 1
            if stateCounter == 0 {
                readWriteActive = false
                state = .sector2
            }

        // WRITE sequence
        case .write0:
            stateCounter = 1
            syncOffset = 0
            state = .write1

        case .write1:
            stateCounter -= 1
            if stateCounter == 0 {
                if syncOffset > 0 {
                    writeCachedSector()
                }
                stateCounter = 2
                state = .write2
            }

        case .write2:
            stateCounter -= 1
            if stateCounter == 0 {
                readWriteActive = false
                state = .sector2
            }

        // End of sector → next
        case .sector2:
            stateCounter = 1  // fast mode
            state = .sector3

        case .sector3:
            stateCounter -= 1
            if stateCounter == 0 {
                state = .sector4
            }

        case .sector4:
            sectorNum += 1
            if sectorNum >= Self.sectorsPerTrack {
                sectorNum = 0
                state = .index0
            } else {
                state = .sector0
            }
        }
    }

    // MARK: - Sector Cache

    private func buildSectorCache() {
        let heads = maxHeads + 1
        freeSectorCache()
        sectorCacheSize = totalSectors * Self.cacheSize
        let cache = UnsafeMutablePointer<UInt8>.allocate(capacity: sectorCacheSize)
        cache.initialize(repeating: 0, count: sectorCacheSize)
        sectorCachePtr = cache

        guard let store = diskStore else { return }

        for i in 0..<totalSectors {
            let baseOffset = i * Self.cacheSize

            // Build header
            let phys = i % 16
            let shftrk = i & 0xFFF0
            var logical = phys
            if phys % 2 != 0 { logical = (logical + 8) % 16 }
            logical += shftrk

            let chead = (i % (16 * heads)) / 16
            let ccyl = i / (16 * heads)
            let cylFactor = UInt8((ccyl & 0x300) >> 4)
            let cylLo = UInt8(ccyl & 0xFF)

            cache[baseOffset + 0] = 0x00  // start marker
            cache[baseOffset + 1] = UInt8(phys) | cylFactor
            cache[baseOffset + 2] = cylLo
            cache[baseOffset + 3] = UInt8(chead) | (i < 16 || i > maxSectors ? 0x80 : 0)
            cache[baseOffset + 4] = UInt8(logical & 0xFF)
            cache[baseOffset + 5] = UInt8(logical >> 8)
            cache[baseOffset + 6] = UInt8(shftrk & 0xFF)
            cache[baseOffset + 7] = UInt8(shftrk >> 8)

            // Header CRC
            var crc: UInt8 = 0
            for j in 1...7 { crc = crc &+ cache[baseOffset + j] }
            cache[baseOffset + 8] = crc
            cache[baseOffset + 9] = ~crc

            // Load 512-byte sector data from file via memcpy
            let fileOffset = i * Self.sectorDataSize
            if fileOffset + Self.sectorDataSize <= diskStoreSize {
                memcpy(cache + baseOffset + Self.headerSize, store + fileOffset, Self.sectorDataSize)
            }

            // Data CRC (over 512 bytes) — sum all data bytes
            let dataStart = cache + baseOffset + Self.headerSize
            var dataCRC: Int = 0
            // Process 8 bytes at a time for speed
            var j = 0
            while j + 7 < Self.sectorDataSize {
                dataCRC += Int(dataStart[j]) + Int(dataStart[j+1]) + Int(dataStart[j+2]) + Int(dataStart[j+3])
                    + Int(dataStart[j+4]) + Int(dataStart[j+5]) + Int(dataStart[j+6]) + Int(dataStart[j+7])
                j += 8
            }
            while j < Self.sectorDataSize {
                dataCRC += Int(dataStart[j])
                j += 1
            }
            let crcHi = UInt8((dataCRC >> 8) & 0xFF)
            let crcLo = UInt8(dataCRC & 0xFF)
            cache[baseOffset + 0x20A] = crcHi
            cache[baseOffset + 0x20B] = crcLo
            cache[baseOffset + 0x20C] = ~crcHi
            cache[baseOffset + 0x20D] = ~crcLo
        }
    }

    private func sectorAddress() -> Int {
        return ((cylinder * (maxHeads + 1)) + surface) * Self.sectorsPerTrack + sectorNum
    }

    private func copyCacheHeader() {
        let addr = sectorAddress()
        guard addr >= 0 && addr < totalSectors, let cache = sectorCachePtr else { return }
        let base = addr * Self.cacheSize
        for k in 0..<Self.headerSize {
            cacheRAM[k] = cache[base + k]
        }
        ramPtr = Self.headerSize
    }

    private func copySectorToRAM() {
        let addr = sectorAddress()
        guard addr >= 0 && addr < totalSectors, let cache = sectorCachePtr else { return }
        let base = addr * Self.cacheSize
        // Copy all 526 bytes (10 header + 512 data + 4 CRC) to cache RAM
        for k in 0..<Self.cacheSize {
            cacheRAM[k] = cache[base + k]
        }
        ramPtr = Self.cacheSize
    }

    private func writeCachedSector() {
        guard syncOffset > 0, let cache = sectorCachePtr, let store = diskStore else { return }

        let physSector = Int(cacheRAM[syncOffset + 1]) & 0x0F
        let cylFactor = Int(cacheRAM[syncOffset + 1] & 0x30) << 4
        let pcylinder = Int(cacheRAM[syncOffset + 2]) | cylFactor
        let psurface = Int(cacheRAM[syncOffset + 3]) & 0x07
        let trackNum = (pcylinder * (maxHeads + 1)) + psurface
        let sectorAddr = trackNum * Self.sectorsPerTrack + physSector
        let fileOffset = sectorAddr * Self.sectorDataSize

        guard sectorAddr >= 0 && sectorAddr < totalSectors else { return }
        let cacheBase = sectorAddr * Self.cacheSize

        // Copy header from write cache to sector cache
        cache[cacheBase] = 0  // start marker
        for j in 1..<Self.headerSize {
            if syncOffset + j < cacheRAM.count {
                cache[cacheBase + j] = cacheRAM[syncOffset + j]
            }
        }

        // Copy 512 data bytes to sector cache AND backing store
        for j in 0..<Self.sectorDataSize {
            let src = syncOffset + Self.headerSize + j
            guard src < cacheRAM.count else { break }
            let byte = cacheRAM[src]
            cache[cacheBase + Self.headerSize + j] = byte
            if fileOffset + j < diskStoreSize {
                store[fileOffset + j] = byte
            }
        }

        // Recalculate data CRC so subsequent reads verify correctly
        var dataCRC: Int = 0
        for j in 0..<Self.sectorDataSize {
            dataCRC += Int(cache[cacheBase + Self.headerSize + j])
        }
        let crcHi = UInt8((dataCRC >> 8) & 0xFF)
        let crcLo = UInt8(dataCRC & 0xFF)
        cache[cacheBase + 0x20A] = crcHi
        cache[cacheBase + 0x20B] = crcLo
        cache[cacheBase + 0x20C] = ~crcHi
        cache[cacheBase + 0x20D] = ~crcLo
    }
}
