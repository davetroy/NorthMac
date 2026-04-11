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
    @StateObject private var emulator = EmulatorCore()
    @State private var availableDisks: [DiskEntry] = []
    @State private var availableHDs: [DiskEntry] = []
    @State private var selectedDisk1: DiskEntry?
    @State private var selectedDisk2: DiskEntry?
    @State private var selectedHD: DiskEntry?
    @State private var showDiskControls = false
    @State private var showCRTControls = false
    @State private var diskWarning: String?
    @State private var showDiskWarning = false
    @State private var setupWarning: String?
    @State private var showSetupWarning = false
    // Per-window display settings, initialized from saved defaults
    @State private var vintageFX: Bool = UserDefaults.standard.object(forKey: "vintageFX") as? Bool ?? true
    @State private var phosphorColorRaw: String = UserDefaults.standard.string(forKey: "phosphorColor") ?? "Green"
    @State private var bloomIntensity: Double = UserDefaults.standard.object(forKey: "bloomIntensity") as? Double ?? 0.6
    @State private var scanlineIntensity: Double = UserDefaults.standard.object(forKey: "scanlineIntensity") as? Double ?? 0.5
    @State private var curvatureIntensity: Double = UserDefaults.standard.object(forKey: "curvatureIntensity") as? Double ?? 0.4
    @State private var screenGlowIntensity: Double = UserDefaults.standard.object(forKey: "screenGlowIntensity") as? Double ?? 0.5
    @Environment(\.controlActiveState) private var controlActiveState

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

            toolbarView
        }
        .frame(minWidth: 800, minHeight: 520)
        .alert("Disk Warning", isPresented: $showDiskWarning) {
            Button("Mount Anyway") { }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(diskWarning ?? "")
        }
        .alert("Setup Required", isPresented: $showSetupWarning) {
            Button("OK") { }
        } message: {
            Text(setupWarning ?? "")
        }
        .onAppear {
            ResourceCache.shared.ensureLoaded { [self] in
                let cache = ResourceCache.shared

                availableDisks = cache.availableDisks
                availableHDs = cache.availableHDs

                let lastDisk1 = UserDefaults.standard.string(forKey: "lastDisk1") ?? ""
                let lastDisk2 = UserDefaults.standard.string(forKey: "lastDisk2") ?? ""
                let lastHD = UserDefaults.standard.string(forKey: "lastHD") ?? ""

                let disk1 = availableDisks.first(where: { $0.name == lastDisk1 })
                    ?? availableDisks.first(where: { $0.name == "advf2_cpm120_wm" })
                    ?? availableDisks.first(where: { $0.validation.isValid })
                let disk2 = lastDisk2.isEmpty ? nil : availableDisks.first(where: { $0.name == lastDisk2 })
                let hd = lastHD.isEmpty ? nil : availableHDs.first(where: { $0.name == lastHD })

                if let disk1 = disk1 { selectedDisk1 = disk1 }
                if let disk2 = disk2 { selectedDisk2 = disk2 }
                if let hd = hd { selectedHD = hd }

                // Notify user about missing resources
                let romAvailable = cache.bootROMData != nil
                var missing: [String] = []
                if !romAvailable {
                    missing.append("• Boot ROM (AdvantageBootRom.bin) — place in Resources/")
                }
                if availableDisks.isEmpty {
                    missing.append("• Floppy disk images (.NSI) — place in Disk Images/Bootable/")
                }
                if !missing.isEmpty {
                    setupWarning = "The following resources are missing:\n\n"
                        + missing.joined(separator: "\n")
                        + "\n\nSee README.md for details on where to find these files."
                    showSetupWarning = true
                }

                let emulator = self.emulator
                DispatchQueue.global(qos: .userInitiated).async {
                    emulator.loadBootROM()
                    if let disk1 = disk1 { emulator.mountDisk(url: disk1.url, drive: 0) }
                    if let disk2 = disk2 { emulator.mountDisk(url: disk2.url, drive: 1) }
                    if let hd = hd { emulator.mountHardDisk(url: hd.url) }
                    DispatchQueue.main.async {
                        emulator.start()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTurbo)) { _ in
            guard isKeyWindow else { return }
            emulator.turboMode.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takeScreenshot)) { _ in
            guard isKeyWindow else { return }
            takeScreenshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mountDisk1)) { _ in
            guard isKeyWindow else { return }
            openDiskPanel(drive: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mountDisk2)) { _ in
            guard isKeyWindow else { return }
            openDiskPanel(drive: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            guard isKeyWindow else { return }
            saveDefaults()
        }
    }

    private var isKeyWindow: Bool {
        controlActiveState == .key
    }

    private func saveDefaults() {
        let ud = UserDefaults.standard
        ud.set(vintageFX, forKey: "vintageFX")
        ud.set(phosphorColorRaw, forKey: "phosphorColor")
        ud.set(bloomIntensity, forKey: "bloomIntensity")
        ud.set(scanlineIntensity, forKey: "scanlineIntensity")
        ud.set(curvatureIntensity, forKey: "curvatureIntensity")
        ud.set(screenGlowIntensity, forKey: "screenGlowIntensity")
        ud.set(emulator.turboMode, forKey: "turboMode")
        ud.set(selectedDisk1?.name ?? "", forKey: "lastDisk1")
        ud.set(selectedDisk2?.name ?? "", forKey: "lastDisk2")
        ud.set(selectedHD?.name ?? "", forKey: "lastHD")
    }

    private func openDiskPanel(drive: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                emulator.mountDisk(url: url, drive: drive)
            }
        }
    }

    private var toolbarView: some View {
        HStack(spacing: 10) {
            Button(emulator.isRunning ? "Pause" : "Resume") {
                if emulator.isRunning { emulator.stop() } else { emulator.start() }
            }
            .keyboardShortcut("p", modifiers: [.command])

            Button("Reset") { emulator.reset() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider().frame(height: 16)

            Button("Disks") { showDiskControls.toggle() }
                .popover(isPresented: $showDiskControls) {
                    DiskControlsView(
                        selectedDisk1: $selectedDisk1,
                        selectedDisk2: $selectedDisk2,
                        selectedHD: $selectedHD,
                        diskCategories: diskCategories,
                        availableHDs: availableHDs,
                        onMountFloppy: { disk, drive in
                            mountWithValidation(disk: disk, drive: drive)
                        },
                        onMountHD: { hd in
                            emulator.mountHardDisk(url: hd.url)
                        }
                    )
                }

            Button("CRT") { showCRTControls.toggle() }
                .popover(isPresented: $showCRTControls) {
                    CRTControlsView(
                        phosphorColorRaw: $phosphorColorRaw,
                        vintageFX: $vintageFX,
                        bloomIntensity: $bloomIntensity,
                        scanlineIntensity: $scanlineIntensity,
                        curvatureIntensity: $curvatureIntensity,
                        screenGlowIntensity: $screenGlowIntensity
                    )
                }

            Toggle("Turbo", isOn: $emulator.turboMode)
                .toggleStyle(.switch)
                .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
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

    // Disk scanning is handled by ResourceCache.shared

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

struct DiskControlsView: View {
    @Binding var selectedDisk1: DiskEntry?
    @Binding var selectedDisk2: DiskEntry?
    @Binding var selectedHD: DiskEntry?
    let diskCategories: [(String, [DiskEntry])]
    let availableHDs: [DiskEntry]
    var onMountFloppy: (DiskEntry, Int) -> Void
    var onMountHD: (DiskEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disk Drives").font(.headline)

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
            .onChange(of: selectedDisk1) { _, disk in
                if let disk = disk { onMountFloppy(disk, 0) }
            }

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
            .onChange(of: selectedDisk2) { _, disk in
                if let disk = disk { onMountFloppy(disk, 1) }
            }

            Divider()

            Picker("Hard Disk", selection: $selectedHD) {
                Text("None").tag(nil as DiskEntry?)
                ForEach(availableHDs) { hd in
                    Text(hd.name).tag(hd as DiskEntry?)
                }
            }
            .onChange(of: selectedHD) { _, hd in
                if let hd = hd { onMountHD(hd) }
            }
        }
        .padding()
        .frame(width: 300)
    }
}

struct CRTControlsView: View {
    @Binding var phosphorColorRaw: String
    @Binding var vintageFX: Bool
    @Binding var bloomIntensity: Double
    @Binding var scanlineIntensity: Double
    @Binding var curvatureIntensity: Double
    @Binding var screenGlowIntensity: Double

    var body: some View {
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
}
