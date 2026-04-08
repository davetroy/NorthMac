import Foundation

/// NSI disk image format handling and validation
struct DiskImage {
    enum Format: String {
        case dsdd  // DSDD: ~350KB — 35 tracks x 2 sides x 10 sectors x 512 bytes (358,400) — NorthStar "Q" format
        case ssdd  // SSDD: ~175KB — 35 tracks x 1 side x 10 sectors x 512 bytes (179,200) — NorthStar "D" format
        case sssd  // SSSD:  ~88KB — 35 tracks x 1 side x 10 sectors x 256 bytes  (89,600) — NorthStar "S" format
    }

    /// Validation result for NSI disk images
    struct ValidationResult {
        let isValid: Bool
        let isBootable: Bool
        let format: Format?
        let platform: Platform
        let hasMED3C: Bool
        let warnings: [String]

        enum Platform: String {
            case advantage = "Advantage"
            case horizon = "Horizon"
            case unknown = "Unknown"
        }

        var summary: String {
            if !isValid { return warnings.first ?? "Invalid disk image" }
            var parts = [platform.rawValue]
            if let f = format {
                parts.append(f.rawValue.uppercased())
            }
            if isBootable { parts.append("bootable") }
            if hasMED3C { parts.append("self-contained") }
            return parts.joined(separator: ", ")
        }
    }

    let data: Data
    let format: Format

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.data = data

        switch data.count {
        case 358_400:
            self.format = .dsdd
        case 179_200:
            self.format = .ssdd
        case 89_600:
            self.format = .sssd
        default:
            if data.count > 200_000 {
                self.format = .dsdd
            } else if data.count > 100_000 {
                self.format = .ssdd
            } else {
                self.format = .sssd
            }
        }
    }

    var tracks: Int { 35 }
    var sides: Int { format == .dsdd ? 2 : 1 }
    var sectorsPerTrack: Int { 10 }
    var bytesPerSector: Int { format == .sssd ? 256 : 512 }

    /// Calculate file offset for a given track/sector/side
    func offset(track: Int, sector: Int, side: Int) -> Int {
        let sectorAddress: Int
        if side != 0 {
            sectorAddress = (((tracks * 2) - 1) - track) * sectorsPerTrack + sector
        } else {
            sectorAddress = track * sectorsPerTrack + sector
        }
        return sectorAddress * bytesPerSector
    }

    // MARK: - Static Validation

    /// Validate an NSI disk image file without fully loading it.
    /// Returns validation result with platform detection and warnings.
    static func validate(url: URL) -> ValidationResult {
        guard let data = try? Data(contentsOf: url) else {
            return ValidationResult(isValid: false, isBootable: false, format: nil, platform: .unknown,
                                    hasMED3C: false, warnings: ["Cannot read file"])
        }
        return validate(data: data, name: url.lastPathComponent)
    }

    /// Validate NSI disk image data.
    static func validate(data: Data, name: String = "") -> ValidationResult {
        var warnings: [String] = []

        // 1. Check file size
        let format: Format?
        switch data.count {
        case 358_400:
            format = .dsdd
        case 179_200:
            format = .ssdd
        case 89_600:
            format = .sssd
            warnings.append("Single density (256-byte sectors) — not yet supported by emulator")
        default:
            format = nil
            warnings.append("Invalid size: \(data.count) bytes (expected 89600, 179200, or 358400)")
        }

        guard format != nil else {
            return ValidationResult(isValid: false, isBootable: false, format: nil, platform: .unknown,
                                    hasMED3C: false, warnings: warnings)
        }

        // 2. Detect platform from signon strings
        let hasAdvantage = data.containsASCII("Advantage")
        let hasHorizon = data.containsASCII("Horizon")
        // "Horizon" can appear in embedded docs (e.g., WordStar help text).
        // Only flag as Horizon platform if "Advantage" is absent.
        let platform: ValidationResult.Platform
        if hasAdvantage {
            platform = .advantage
        } else if hasHorizon {
            platform = .horizon
            warnings.append("Horizon disk — incompatible with Advantage hardware")
        } else {
            platform = .unknown
            warnings.append("No platform signon found (may still work)")
        }

        // 3. Check for MED3C signature (ED 73 7A FD = LD (FD7A),SP)
        let med3cSig: [UInt8] = [0xED, 0x73, 0x7A, 0xFD]
        let hasMED3C = data.containsBytes(med3cSig)

        // 4. Check boot sector structure for bootability
        // Boot ROM reads sector 4 (offset 0x800). First data byte = load page.
        // Second byte should be a Z80 instruction (C3=JP, F3=DI, 21=LD HL, etc.)
        // Blank sectors (all 00) or pure text (ASCII) are not bootable.
        var isBootable = false
        if data.count > 0x810 {
            let loadPage = data[0x800]
            let secondByte = data[0x801]
            let sector4AllZero = data[0x800..<0x810].allSatisfy { $0 == 0 }

            if !sector4AllZero && loadPage >= 0x80 {
                // Load page in upper memory (0x80+) with non-zero code = bootable
                // Known good: 0xC0, 0xDF, 0xEC, 0xF2, 0xF8
                // Second byte is typically: C3 (JP), 21 (LD HL), F3 (DI), 11 (LD DE)
                let validEntry = [0xC3, 0xF3, 0x21, 0x11, 0x31, 0x3E, 0x00].contains(secondByte)
                isBootable = validEntry
            }
        }

        if platform == .advantage && !isBootable && format != .sssd {
            warnings.append("No valid boot sector detected")
        }

        let isValid = platform != .horizon && format != nil
        return ValidationResult(isValid: isValid, isBootable: isBootable, format: format,
                                platform: platform, hasMED3C: hasMED3C, warnings: warnings)
    }
}

// MARK: - Data search helpers

extension Data {
    /// Check if data contains an ASCII string (case-sensitive)
    func containsASCII(_ string: String) -> Bool {
        guard let needle = string.data(using: .ascii) else { return false }
        return self.range(of: needle) != nil
    }

    /// Check if data contains a byte sequence
    func containsBytes(_ bytes: [UInt8]) -> Bool {
        let needle = Data(bytes)
        return self.range(of: needle) != nil
    }
}
