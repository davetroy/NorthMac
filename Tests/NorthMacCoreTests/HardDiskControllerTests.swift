import XCTest
@testable import NorthMacCore

final class HardDiskControllerTests: XCTestCase {
    var hdc: HardDiskController!
    var tempDir: URL!
    var diskURL: URL!
    var sampleData: Data!

    override func setUp() {
        super.setUp()
        hdc = HardDiskController()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NorthMacHDCTests-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        diskURL = tempDir.appendingPathComponent("test.nhd")
        sampleData = makeValidNHD(sizeKB: 256)
        try! sampleData.write(to: diskURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Build a minimum-viable NHD blob: 0x00 0xFF magic, label fields populated.
    private func makeValidNHD(sizeKB: Int) -> Data {
        var d = Data(count: sizeKB * 1024)
        d[0] = 0x00
        d[1] = 0xFF
        // Label fields (offsets per HardDiskController.mount)
        d[39] = 0x00       // maxSectors lo
        d[40] = 0x05       // maxSectors hi → 0x0500 = 1280
        d[49] = 0x03       // maxHeads (0-based: 4 heads)
        d[50] = 0x99       // maxCylinders lo
        d[51] = 0x00       // maxCylinders hi → 0x0099 = 153
        return d
    }

    // MARK: - Mount validation

    func testMountRejectsMissingMagicBytes() {
        let bad = Data(repeating: 0xCC, count: 256)  // no 0x00 0xFF prefix
        hdc.mount(url: diskURL, data: bad, writeProtect: true)
        XCTAssertFalse(hdc.mounted, "NHD without magic bytes must be rejected")
        XCTAssertNil(hdc.sourceURL)
    }

    func testMountRejectsTruncatedFile() {
        let tiny = Data([0x00, 0xFF, 0x00, 0x00])  // valid magic but < 128 bytes
        hdc.mount(url: diskURL, data: tiny, writeProtect: true)
        XCTAssertFalse(hdc.mounted)
    }

    func testMountAcceptsValidNHD() {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: true)
        XCTAssertTrue(hdc.mounted)
        XCTAssertEqual(hdc.sourceURL, diskURL)
        XCTAssertEqual(hdc.fileName, "test.nhd")
        XCTAssertFalse(hdc.dirty)
        XCTAssertTrue(hdc.writeProtect)
    }

    func testMountWriteProtectFalse() {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: false)
        XCTAssertFalse(hdc.writeProtect)
    }

    func testMountParsesGeometryFromLabel() {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: true)
        XCTAssertEqual(hdc.maxSectors, 0x0500)
        XCTAssertEqual(hdc.maxHeads, 3)
        XCTAssertEqual(hdc.maxCylinders, 0x0099)
    }

    // MARK: - Unmount

    func testUnmountClearsState() {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: false)
        hdc.dirty = true
        hdc.unmount()
        XCTAssertFalse(hdc.mounted)
        XCTAssertNil(hdc.sourceURL)
        XCTAssertEqual(hdc.fileName, "")
        XCTAssertFalse(hdc.dirty, "Unmount must clear dirty")
    }

    // MARK: - flushIfDirty

    func testFlushNoOpWhenClean() throws {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: false)
        XCTAssertFalse(hdc.flushIfDirty())
        let bakURL = diskURL.appendingPathExtension("bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakURL.path))
        let onDisk = try Data(contentsOf: diskURL)
        XCTAssertEqual(onDisk, sampleData, "File untouched when not dirty")
    }

    func testFlushNoOpWhenWriteProtected() {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: true)
        hdc.dirty = true
        XCTAssertFalse(hdc.flushIfDirty())
        XCTAssertTrue(hdc.dirty, "Failed flush must leave dirty set")
        let bakURL = diskURL.appendingPathExtension("bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakURL.path))
    }

    func testFlushNoOpWhenUnmounted() {
        // Never mounted — flush must early-out.
        hdc.dirty = true
        XCTAssertFalse(hdc.flushIfDirty())
    }

    func testFlushSucceedsWhenDirtyAndWritable() throws {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: false)
        hdc.dirty = true

        XCTAssertTrue(hdc.flushIfDirty())
        XCTAssertFalse(hdc.dirty, "Successful flush must clear dirty")

        // Backup contains the original bytes.
        let bakURL = diskURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakURL.path))
        let bakData = try Data(contentsOf: bakURL)
        XCTAssertEqual(bakData, sampleData, "Backup must match original pre-flush bytes")

        // File on disk size unchanged (no sector writes happened, just a re-flush of the
        // existing diskStore which was loaded from the same bytes).
        let onDisk = try Data(contentsOf: diskURL)
        XCTAssertEqual(onDisk.count, sampleData.count)
    }

    func testFlushBackupCreatedOnceOnly() throws {
        hdc.mount(url: diskURL, data: sampleData, writeProtect: false)
        hdc.dirty = true
        XCTAssertTrue(hdc.flushIfDirty())

        let bakURL = diskURL.appendingPathExtension("bak")
        let firstAttrs = try FileManager.default.attributesOfItem(atPath: bakURL.path)
        let firstModDate = firstAttrs[.modificationDate] as! Date

        Thread.sleep(forTimeInterval: 1.1)  // mtime granularity
        hdc.dirty = true
        XCTAssertTrue(hdc.flushIfDirty())

        let secondAttrs = try FileManager.default.attributesOfItem(atPath: bakURL.path)
        let secondModDate = secondAttrs[.modificationDate] as! Date
        XCTAssertEqual(firstModDate, secondModDate,
                       "Backup must only be written on the first flush, not subsequent ones")
    }
}
