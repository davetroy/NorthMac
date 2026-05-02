import XCTest
@testable import NorthMacCore

final class FloppyDiskControllerTests: XCTestCase {
    var fdc: FloppyDiskController!
    var tempDir: URL!
    var diskURL: URL!
    var sampleData: Data!

    override func setUp() {
        super.setUp()
        fdc = FloppyDiskController()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NorthMacFDCTests-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        diskURL = tempDir.appendingPathComponent("test.nsi")
        // 350KB double-sided NSI image, all bytes 0xAA so we can detect modifications.
        sampleData = Data(repeating: 0xAA, count: 350 * 1024)
        try! sampleData.write(to: diskURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Mount

    func testMountSetsBasicState() {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: true)
        XCTAssertEqual(fdc.drives[0].sourceURL, diskURL)
        XCTAssertEqual(fdc.drives[0].fileName, "test.nsi")
        XCTAssertFalse(fdc.drives[0].dirty)
        XCTAssertTrue(fdc.drives[0].writeProtect)
        XCTAssertEqual(fdc.drives[0].diskData?.count, sampleData.count)
        XCTAssertEqual(fdc.drives[0].trackNum, 0)
        XCTAssertTrue(fdc.drives[0].track0)
    }

    func testMountWriteProtectFalse() {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: false)
        XCTAssertFalse(fdc.drives[0].writeProtect)
    }

    func testMountDriveOutOfRangeIsIgnored() {
        // Drive 5 doesn't exist — must not crash and must not mutate other drives.
        fdc.mountDisk(drive: 5, url: diskURL, data: sampleData, writeProtect: false)
        XCTAssertNil(fdc.drives[0].sourceURL)
        XCTAssertNil(fdc.drives[1].sourceURL)
    }

    // MARK: - writeSectorToDisk gating

    func testWriteSectorWithWPDoesNotMutateAndDoesNotMarkDirty() {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: true)
        // Drop a sentinel into the FDC's sector buffer (in the active drive).
        for i in 0..<512 { fdc.drives[0].dataBuffer[i] = 0x55 }
        fdc.drives[0].trackNum = 0
        fdc.drives[0].sectorNum = 0
        fdc.drives[0].side = 0

        fdc.writeSectorToDisk()

        XCTAssertFalse(fdc.drives[0].dirty, "WP must not mark drive dirty")
        // diskData[0] should still be 0xAA, not 0x55.
        XCTAssertEqual(fdc.drives[0].diskData![0], 0xAA, "WP must prevent in-memory modification")
    }

    func testWriteSectorWithoutWPMutatesAndMarksDirty() {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: false)
        for i in 0..<512 { fdc.drives[0].dataBuffer[i] = 0x42 }
        fdc.drives[0].trackNum = 0
        fdc.drives[0].sectorNum = 0
        fdc.drives[0].side = 0

        fdc.writeSectorToDisk()

        XCTAssertTrue(fdc.drives[0].dirty, "Successful write must mark dirty")
        XCTAssertEqual(fdc.drives[0].diskData![0], 0x42, "Sector 0 byte 0 must be the new value")
        XCTAssertEqual(fdc.drives[0].diskData![511], 0x42)
        // Byte 512 belongs to the next sector and must be untouched.
        XCTAssertEqual(fdc.drives[0].diskData![512], 0xAA)
    }

    func testWriteSectorOffsetForTrackAndSector() {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: false)
        // Track 1, sector 3, side 0 → storeSectNum = 1*10 + 3 = 13 → offset 13*512 = 6656.
        for i in 0..<512 { fdc.drives[0].dataBuffer[i] = 0x77 }
        fdc.drives[0].trackNum = 1
        fdc.drives[0].sectorNum = 3
        fdc.drives[0].side = 0

        fdc.writeSectorToDisk()

        let expectedOffset = 13 * 512
        XCTAssertEqual(fdc.drives[0].diskData![expectedOffset], 0x77)
        XCTAssertEqual(fdc.drives[0].diskData![expectedOffset + 511], 0x77)
        XCTAssertEqual(fdc.drives[0].diskData![expectedOffset - 1], 0xAA, "Previous sector untouched")
        XCTAssertEqual(fdc.drives[0].diskData![expectedOffset + 512], 0xAA, "Next sector untouched")
    }

    // MARK: - flushIfDirty

    func testFlushNoOpWhenClean() throws {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: false)
        XCTAssertFalse(fdc.flushIfDirty(drive: 0))
        let bakURL = diskURL.appendingPathExtension("bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakURL.path),
                       "Clean drive must not produce a backup")
        // File on disk untouched.
        let onDisk = try Data(contentsOf: diskURL)
        XCTAssertEqual(onDisk, sampleData)
    }

    func testFlushNoOpWhenWriteProtected() throws {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: true)
        // Force the dirty flag — should still no-op because WP guards the flush.
        fdc.drives[0].dirty = true

        XCTAssertFalse(fdc.flushIfDirty(drive: 0))
        XCTAssertTrue(fdc.drives[0].dirty, "Failed flush must leave dirty set")
        let bakURL = diskURL.appendingPathExtension("bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakURL.path))
    }

    func testFlushNoOpWhenNoSourceURL() {
        // Drive that was never mounted has nil sourceURL.
        fdc.drives[0].dirty = true
        fdc.drives[0].diskData = sampleData
        fdc.drives[0].writeProtect = false
        fdc.drives[0].sourceURL = nil
        XCTAssertFalse(fdc.flushIfDirty(drive: 0))
    }

    func testFlushNoOpForOutOfRangeDrive() {
        XCTAssertFalse(fdc.flushIfDirty(drive: 5))
        XCTAssertFalse(fdc.flushIfDirty(drive: -1))
    }

    func testFlushWritesFileAndCreatesBackupOnFirstFlush() throws {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: false)
        // Mount leaves sectorNum=9; force track/sector/side so the write lands at offset 0.
        fdc.drives[0].trackNum = 0
        fdc.drives[0].sectorNum = 0
        fdc.drives[0].side = 0
        for i in 0..<512 { fdc.drives[0].dataBuffer[i] = 0x42 }
        fdc.writeSectorToDisk()
        XCTAssertTrue(fdc.drives[0].dirty)

        XCTAssertTrue(fdc.flushIfDirty(drive: 0))
        XCTAssertFalse(fdc.drives[0].dirty, "Flush must clear dirty on success")

        // Backup contains pre-flush content.
        let bakURL = diskURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakURL.path))
        let bakData = try Data(contentsOf: bakURL)
        XCTAssertEqual(bakData, sampleData, "Backup must match the original pre-flush bytes")

        // Original file contains the new content.
        let newData = try Data(contentsOf: diskURL)
        XCTAssertEqual(newData.count, sampleData.count)
        XCTAssertEqual(newData[0], 0x42)
        XCTAssertEqual(newData[511], 0x42)
        XCTAssertEqual(newData[512], 0xAA, "Next sector must remain unchanged")
    }

    func testFlushBackupCreatedOnceOnly() throws {
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: false)
        fdc.drives[0].dirty = true
        XCTAssertTrue(fdc.flushIfDirty(drive: 0))

        let bakURL = diskURL.appendingPathExtension("bak")
        let firstAttrs = try FileManager.default.attributesOfItem(atPath: bakURL.path)
        let firstModDate = firstAttrs[.modificationDate] as! Date

        // Mutate again and flush again. Backup must NOT be re-copied.
        Thread.sleep(forTimeInterval: 1.1)  // FS mtime granularity is ~1s on APFS for some paths
        fdc.drives[0].diskData![0] = 0xFF
        fdc.drives[0].dirty = true
        XCTAssertTrue(fdc.flushIfDirty(drive: 0))

        let secondAttrs = try FileManager.default.attributesOfItem(atPath: bakURL.path)
        let secondModDate = secondAttrs[.modificationDate] as! Date
        XCTAssertEqual(firstModDate, secondModDate,
                       "Backup must only be written on the first flush, not subsequent ones")
    }

    func testFlushAllIteratesBothDrives() throws {
        let url2 = tempDir.appendingPathComponent("test2.nsi")
        try sampleData.write(to: url2)
        fdc.mountDisk(drive: 0, url: diskURL, data: sampleData, writeProtect: false)
        fdc.mountDisk(drive: 1, url: url2, data: sampleData, writeProtect: false)
        fdc.drives[0].dirty = true
        fdc.drives[1].dirty = true

        fdc.flushAll()

        XCTAssertFalse(fdc.drives[0].dirty)
        XCTAssertFalse(fdc.drives[1].dirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            diskURL.appendingPathExtension("bak").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            url2.appendingPathExtension("bak").path))
    }
}
