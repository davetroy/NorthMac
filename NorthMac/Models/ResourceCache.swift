import Foundation

/// App-wide cache for boot ROM and disk catalog, loaded once and shared across windows.
final class ResourceCache {
    static let shared = ResourceCache()

    /// Cached boot ROM bytes (nil if not found)
    private(set) var bootROMData: [UInt8]?

    /// Cached disk catalog
    private(set) var availableDisks: [DiskEntry] = []
    private(set) var availableHDs: [DiskEntry] = []

    /// Whether the cache has been populated
    private(set) var isLoaded = false

    private let queue = DispatchQueue(label: "com.northmac.resource-cache")
    private var loadCallbacks: [() -> Void] = []
    private var loading = false

    private init() {}

    /// Ensure resources are loaded, then call back on the main queue.
    /// First caller triggers the load; subsequent callers get the cached result immediately.
    func ensureLoaded(completion: @escaping () -> Void) {
        queue.sync {
            if isLoaded {
                DispatchQueue.main.async { completion() }
                return
            }
            loadCallbacks.append(completion)
            if loading { return }
            loading = true
            DispatchQueue.global(qos: .userInitiated).async { self.load() }
        }
    }

    private func load() {
        let rom = Self.findBootROM()
        let (disks, hds) = Self.scanDisks()

        queue.sync {
            self.bootROMData = rom
            self.availableDisks = disks
            self.availableHDs = hds
            self.isLoaded = true
            let callbacks = self.loadCallbacks
            self.loadCallbacks = []
            DispatchQueue.main.async {
                for cb in callbacks { cb() }
            }
        }
    }

    // MARK: - Boot ROM

    private static func findBootROM() -> [UInt8]? {
        var romData: Data?

        if let bundleURL = Bundle.main.url(forResource: "AdvantageBootRom", withExtension: "bin") {
            romData = try? Data(contentsOf: bundleURL)
        }
        if romData == nil {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let romURL = appSupport?.appendingPathComponent("NorthMac/AdvantageBootRom.bin") {
                romData = try? Data(contentsOf: romURL)
            }
        }
        if romData == nil {
            let romURL = EmulatorCore.projectRoot.appendingPathComponent("Resources/AdvantageBootRom.bin")
            romData = try? Data(contentsOf: romURL)
        }

        guard let data = romData else {
            print("ERROR: Could not load boot ROM")
            return nil
        }
        print("Boot ROM loaded: \(data.count) bytes")
        return Array(data)
    }

    // MARK: - Disk scanning

    private static func scanDisks() -> ([DiskEntry], [DiskEntry]) {
        let fm = FileManager.default
        var disks: [DiskEntry] = []

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let diskImagesDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("Disk Images").path,
            appSupport?.appendingPathComponent("NorthMac/Disk Images").path,
            EmulatorCore.projectRoot.appendingPathComponent("Disk Images").path
        ].compactMap { $0 }

        let categories = ["Bootable", "Non-Bootable", "Unknown"]

        for base in diskImagesDirs {
            for category in categories {
                let dir = (base as NSString).appendingPathComponent(category)
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items.sorted() where item.uppercased().hasSuffix(".NSI") {
                    let full = (dir as NSString).appendingPathComponent(item)
                    let name = (item as NSString).deletingPathExtension
                    guard !disks.contains(where: { $0.name == name }) else { continue }
                    let url = URL(fileURLWithPath: full)
                    let validation = DiskImage.quickValidate(url: url)
                    disks.append(DiskEntry(id: full, name: name, url: url,
                                           category: category, validation: validation))
                }
            }
        }

        var hds: [DiskEntry] = []
        let hdDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("Hard Disks").path,
            appSupport?.appendingPathComponent("NorthMac/Hard Disks").path,
            EmulatorCore.projectRoot.appendingPathComponent("Hard Disks").path
        ].compactMap { $0 }
        for dir in hdDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items.sorted() where item.uppercased().hasSuffix(".NHD") {
                let name = (item as NSString).deletingPathExtension
                guard !hds.contains(where: { $0.name == name }) else { continue }
                let full = (dir as NSString).appendingPathComponent(item)
                let url = URL(fileURLWithPath: full)
                let valid: Bool
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                   data.count >= 128, data[0] == 0x00, data[1] == 0xFF {
                    valid = true
                } else {
                    valid = false
                }
                let validation = DiskImage.ValidationResult(
                    isValid: valid, isBootable: valid, format: nil,
                    platform: .advantage, hasMED3C: false,
                    warnings: valid ? [] : ["Invalid NHD file"])
                hds.append(DiskEntry(id: full, name: name, url: url,
                                     category: "Hard Disk", validation: validation))
            }
        }
        return (disks, hds)
    }
}
