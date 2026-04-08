import SwiftUI

struct DiskEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let category: String  // folder name: "Bootable", "Non-Bootable", "Unknown"
    let validation: DiskImage.ValidationResult

    static func == (lhs: DiskEntry, rhs: DiskEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ContentView: View {
    @ObservedObject var emulator: EmulatorCore
    @State private var availableDisks: [DiskEntry] = []
    @State private var availableHDs: [DiskEntry] = []
    @State private var selectedDisk1: DiskEntry?
    @State private var selectedDisk2: DiskEntry?
    @State private var selectedHD: DiskEntry?
    @AppStorage("lastDisk1") private var lastDisk1Name = ""
    @AppStorage("lastDisk2") private var lastDisk2Name = ""
    @AppStorage("lastHD") private var lastHDName = ""
    @State private var showCRTControls = false
    @State private var diskWarning: String?
    @State private var showDiskWarning = false
    @AppStorage("vintageFX") private var vintageFX = true
    @AppStorage("phosphorColor") private var phosphorColorRaw = "Green"
    @AppStorage("bloomIntensity") private var bloomIntensity: Double = 0.6
    @AppStorage("scanlineIntensity") private var scanlineIntensity: Double = 0.5
    @AppStorage("curvatureIntensity") private var curvatureIntensity: Double = 0.4
    @AppStorage("screenGlowIntensity") private var screenGlowIntensity: Double = 0.5
    @AppStorage("turboMode") private var turboModeSaved = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let inset: CGFloat = 13
                let available = CGSize(width: geo.size.width - inset * 2,
                                       height: geo.size.height - inset * 2)
                // Maintain 4:3 aspect ratio
                let fitW = available.width
                let fitH = fitW * 3.0 / 4.0
                let (w, h): (CGFloat, CGFloat) = fitH <= available.height
                    ? (fitW, fitH)
                    : (available.height * 4.0 / 3.0, available.height)

                MetalEmulatorDisplayView(emulator: emulator,
                    phosphor: PhosphorColor(rawValue: phosphorColorRaw) ?? .green,
                    bloom: vintageFX ? bloomIntensity : 0,
                    scanline: vintageFX ? scanlineIntensity : 0,
                    curvature: vintageFX ? curvatureIntensity : 0,
                    screenGlow: vintageFX ? screenGlowIntensity : 0)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(Color.black)

            // Bottom toolbar
            HStack(spacing: 10) {
                Button(emulator.isRunning ? "Pause" : "Resume") {
                    if emulator.isRunning { emulator.stop() } else { emulator.start() }
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button("Reset") { emulator.reset() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider().frame(height: 16)

                // Drive 1 disk picker
                Picker("Drive 1", selection: $selectedDisk1) {
                    Text("None").tag(nil as DiskEntry?)
                    ForEach(diskCategories, id: \.0) { category, disks in
                        Section(category) {
                            ForEach(disks) { disk in
                                Text(disk.name).tag(disk as DiskEntry?)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .onChange(of: selectedDisk1) { _, disk in
                    if let disk = disk {
                        mountWithValidation(disk: disk, drive: 0)
                        lastDisk1Name = disk.name
                    }
                }

                // Drive 2 disk picker
                Picker("Drive 2", selection: $selectedDisk2) {
                    Text("None").tag(nil as DiskEntry?)
                    ForEach(diskCategories, id: \.0) { category, disks in
                        Section(category) {
                            ForEach(disks) { disk in
                                Text(disk.name).tag(disk as DiskEntry?)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .onChange(of: selectedDisk2) { _, disk in
                    if let disk = disk {
                        mountWithValidation(disk: disk, drive: 1)
                        lastDisk2Name = disk.name
                    }
                }

                // Hard disk picker
                Picker("HD", selection: $selectedHD) {
                    Text("None").tag(nil as DiskEntry?)
                    ForEach(availableHDs) { hd in
                        Text(hd.name).tag(hd as DiskEntry?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .onChange(of: selectedHD) { _, hd in
                    if let hd = hd {
                        emulator.mountHardDisk(url: hd.url)
                        lastHDName = hd.name
                    }
                }

                Divider().frame(height: 16)

                Button("CRT") { showCRTControls.toggle() }
                    .popover(isPresented: $showCRTControls) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Display").font(.headline)
                            Picker("Phosphor", selection: $phosphorColorRaw) {
                                ForEach(PhosphorColor.allCases, id: \.self) { color in
                                    Text(color.rawValue).tag(color.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            Divider()
                            Toggle("Vintage FX", isOn: $vintageFX)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            HStack { Text("Bloom"); Spacer(); Slider(value: $bloomIntensity, in: 0...1).frame(width: 120) }
                                .disabled(!vintageFX)
                            HStack { Text("Scanlines"); Spacer(); Slider(value: $scanlineIntensity, in: 0...1).frame(width: 120) }
                                .disabled(!vintageFX)
                            HStack { Text("Curvature"); Spacer(); Slider(value: $curvatureIntensity, in: 0...1).frame(width: 120) }
                                .disabled(!vintageFX)
                            HStack { Text("Brightness"); Spacer(); Slider(value: $screenGlowIntensity, in: 0...1).frame(width: 120) }
                                .disabled(!vintageFX)
                        }
                        .padding()
                        .frame(width: 280)
                    }

                Toggle("Turbo", isOn: $emulator.turboMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: emulator.turboMode) { _, newVal in
                        turboModeSaved = newVal
                    }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .frame(minWidth: 800, minHeight: 520)
        .alert("Disk Warning", isPresented: $showDiskWarning) {
            Button("Mount Anyway") { }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(diskWarning ?? "")
        }
        .onAppear {
            scanForDisks()
            emulator.loadBootROM()

            // Restore last disk selections, or fall back to defaults
            // Prefer Advantage disks for auto-selection
            let disk1 = availableDisks.first(where: { $0.name == lastDisk1Name })
                ?? availableDisks.first(where: { $0.name == "advf2_cpm120_wm" })
                ?? availableDisks.first(where: { $0.validation.isValid })
            if let disk1 = disk1 {
                selectedDisk1 = disk1
                mountWithValidation(disk: disk1, drive: 0)
            }
            if !lastDisk2Name.isEmpty, let disk2 = availableDisks.first(where: { $0.name == lastDisk2Name }) {
                selectedDisk2 = disk2
                mountWithValidation(disk: disk2, drive: 1)
            }

            // Restore hard disk selection
            if !lastHDName.isEmpty, let hd = availableHDs.first(where: { $0.name == lastHDName }) {
                selectedHD = hd
                emulator.mountHardDisk(url: hd.url)
            }

            emulator.turboMode = turboModeSaved
            emulator.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTurbo)) { _ in
            emulator.turboMode.toggle()
            turboModeSaved = emulator.turboMode
        }
        .onReceive(NotificationCenter.default.publisher(for: .takeScreenshot)) { _ in
            takeScreenshot()
        }
    }

    /// Disks grouped by category for sectioned picker
    private var diskCategories: [(String, [DiskEntry])] {
        let order = ["Bootable", "Non-Bootable", "Unknown"]
        return order.compactMap { cat in
            let disks = availableDisks.filter { $0.category == cat }
            return disks.isEmpty ? nil : (cat, disks)
        }
    }

    /// Mount disk with validation — warns user about incompatible images
    private func mountWithValidation(disk: DiskEntry, drive: Int) {
        if !disk.validation.isValid && !disk.validation.warnings.isEmpty {
            diskWarning = "\(disk.name): \(disk.validation.warnings.joined(separator: "\n"))"
            showDiskWarning = true
        }
        emulator.mountDisk(url: disk.url, drive: drive)
    }

    private func scanForDisks() {
        let fm = FileManager.default
        var disks: [DiskEntry] = []

        // Disk images live in categorized subfolders of "Disk Images/"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let diskImagesDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("Disk Images").path,
            appSupport?.appendingPathComponent("NorthMac/Disk Images").path
        ].compactMap { $0 }

        let categories = ["Bootable", "Non-Bootable", "Unknown"]

        for base in diskImagesDirs {
            for category in categories {
                let dir = (base as NSString).appendingPathComponent(category)
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items.sorted() where item.uppercased().hasSuffix(".NSI") {
                    let full = (dir as NSString).appendingPathComponent(item)
                    let name = (item as NSString).deletingPathExtension
                    // Deduplicate by name (bundle takes priority over dev path)
                    guard !disks.contains(where: { $0.name == name }) else { continue }
                    let url = URL(fileURLWithPath: full)
                    let validation = DiskImage.validate(url: url)
                    disks.append(DiskEntry(id: full, name: name, url: url,
                                           category: category, validation: validation))
                }
            }
        }

        availableDisks = disks

        // Scan for hard disk images (.nhd/.NHD)
        var hds: [DiskEntry] = []
        let hdDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("Hard Disks").path,
            appSupport?.appendingPathComponent("NorthMac/Hard Disks").path
        ].compactMap { $0 }
        for dir in hdDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items.sorted() where item.uppercased().hasSuffix(".NHD") {
                let name = (item as NSString).deletingPathExtension
                guard !hds.contains(where: { $0.name == name }) else { continue }
                let full = (dir as NSString).appendingPathComponent(item)
                let url = URL(fileURLWithPath: full)
                // Quick validation: check magic bytes
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
        availableHDs = hds
    }

    private func takeScreenshot() {
        guard let window = NSApplication.shared.mainWindow,
              let metalView = MetalDisplayNSView.current else {
            NSSound.beep()
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let filename = "NorthMac Screenshot \(df.string(from: Date())).png"
        // Use the system screenshot location (defaults read com.apple.screencapture location)
        let screenshotDir: String
        let task0 = Process()
        let pipe0 = Pipe()
        task0.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task0.arguments = ["read", "com.apple.screencapture", "location"]
        task0.standardOutput = pipe0
        task0.standardError = FileHandle.nullDevice
        try? task0.run()
        task0.waitUntilExit()
        let dirOutput = String(data: pipe0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !dirOutput.isEmpty {
            screenshotDir = NSString(string: dirOutput).expandingTildeInPath
        } else {
            screenshotDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.path
        }
        try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
        let desktopPath = (screenshotDir as NSString).appendingPathComponent(filename)

        // Capture whole window with screencapture -l (already permitted)
        let tmpPath = NSTemporaryDirectory() + "northmac_tmp_screenshot.png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-l", "\(window.windowNumber)", tmpPath]
        try? task.run()
        task.waitUntilExit()

        guard let fullImage = NSImage(contentsOfFile: tmpPath),
              let fullRep = fullImage.tiffRepresentation,
              let fullBitmap = NSBitmapImageRep(data: fullRep),
              let fullCG = fullBitmap.cgImage else {
            try? FileManager.default.removeItem(atPath: tmpPath)
            return
        }

        // Calculate Metal view rect within window (in backing pixels)
        let viewFrame = metalView.convert(metalView.bounds, to: nil)
        let windowHeight = window.frame.height
        let scale = window.backingScaleFactor

        let cropRect = CGRect(
            x: viewFrame.origin.x * scale,
            y: (windowHeight - viewFrame.maxY) * scale,
            width: viewFrame.width * scale,
            height: viewFrame.height * scale
        )

        // Crop to just the CRT display
        if let cropped = fullCG.cropping(to: cropRect) {
            let rep = NSBitmapImageRep(cgImage: cropped)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: desktopPath))
            }
        }

        try? FileManager.default.removeItem(atPath: tmpPath)

        if FileManager.default.fileExists(atPath: desktopPath) {
            NSSound(named: "Grab")?.play()
        }
    }
}
