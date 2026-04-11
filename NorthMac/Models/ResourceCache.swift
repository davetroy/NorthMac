import Foundation

/// App-wide cache for boot ROM and disk catalog, loaded once and shared across windows.
/// Disk validation results are persisted to a JSON file so subsequent launches skip I/O.
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
        let validationCache = Self.loadValidationCache()
        var updatedCache = validationCache
        let (disks, hds) = Self.scanDisks(validationCache: validationCache, updatedCache: &updatedCache)
        if updatedCache != validationCache {
            Self.saveValidationCache(updatedCache)
        }

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

    // MARK: - Validation cache (JSON)

    /// Key: "filename:size:modDate" → cached ValidationResult fields
    private typealias ValidationCacheMap = [String: CachedValidation]

    private struct CachedValidation: Codable, Equatable {
        let isValid: Bool
        let isBootable: Bool
        let format: String?  // "dsdd", "ssdd", "sssd", or nil
        let platform: String // "Advantage", "Horizon", "Unknown"
        let hasMED3C: Bool
        let warnings: [String]
    }

    private static var validationCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("NorthMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("disk_validation_cache.json")
    }

    private static func cacheKey(path: String, size: Int, modDate: Date) -> String {
        let name = (path as NSString).lastPathComponent
        let ts = Int(modDate.timeIntervalSince1970)
        return "\(name):\(size):\(ts)"
    }

    private static func loadValidationCache() -> ValidationCacheMap {
        guard let data = try? Data(contentsOf: validationCacheURL),
              let map = try? JSONDecoder().decode(ValidationCacheMap.self, from: data) else {
            return [:]
        }
        return map
    }

    private static func saveValidationCache(_ map: ValidationCacheMap) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: validationCacheURL, options: .atomic)
    }

    private static func toValidationResult(_ cached: CachedValidation) -> DiskImage.ValidationResult {
        let format: DiskImage.Format? = cached.format.flatMap { DiskImage.Format(rawValue: $0) }
        let platform: DiskImage.ValidationResult.Platform =
            DiskImage.ValidationResult.Platform(rawValue: cached.platform) ?? .unknown
        return DiskImage.ValidationResult(
            isValid: cached.isValid, isBootable: cached.isBootable, format: format,
            platform: platform, hasMED3C: cached.hasMED3C, warnings: cached.warnings)
    }

    private static func toCachedValidation(_ v: DiskImage.ValidationResult) -> CachedValidation {
        CachedValidation(
            isValid: v.isValid, isBootable: v.isBootable,
            format: v.format?.rawValue, platform: v.platform.rawValue,
            hasMED3C: v.hasMED3C, warnings: v.warnings)
    }

    // MARK: - Disk scanning

    private static func scanDisks(validationCache: ValidationCacheMap,
                                   updatedCache: inout ValidationCacheMap) -> ([DiskEntry], [DiskEntry]) {
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

                    // Look up cached validation by file identity (name + size + mod date)
                    let validation: DiskImage.ValidationResult
                    if let attrs = try? fm.attributesOfItem(atPath: full),
                       let size = attrs[.size] as? Int,
                       let modDate = attrs[.modificationDate] as? Date {
                        let key = cacheKey(path: full, size: size, modDate: modDate)
                        if let cached = validationCache[key] {
                            validation = toValidationResult(cached)
                        } else {
                            // Full validate once, then cache
                            validation = DiskImage.validate(url: url)
                            updatedCache[key] = toCachedValidation(validation)
                        }
                    } else {
                        validation = DiskImage.quickValidate(url: url)
                    }

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

                // Just check file size for NHD — no need to read magic bytes at scan time
                let attrs = try? fm.attributesOfItem(atPath: full)
                let size = attrs?[.size] as? Int ?? 0
                let valid = size >= 128
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
