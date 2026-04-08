import SwiftUI

extension Notification.Name {
    static let toggleTurbo = Notification.Name("toggleTurbo")
    static let takeScreenshot = Notification.Name("takeScreenshot")
}

@main
struct NorthMacApp: App {
    @StateObject private var emulator = EmulatorCore()

    var body: some Scene {
        WindowGroup {
            ContentView(emulator: emulator)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Mount Disk Image...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.data]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            emulator.mountDisk(url: url, drive: 0)
                        }
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Mount Disk Image to Drive 2...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.data]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            emulator.mountDisk(url: url, drive: 1)
                        }
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Toggle Turbo") {
                    NotificationCenter.default.post(name: .toggleTurbo, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
            }

            // Replace the default Save command with Screenshot
            CommandGroup(replacing: .saveItem) {
                Button("Save Screenshot") {
                    NotificationCenter.default.post(name: .takeScreenshot, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }

    private func saveScreenshot() {
        guard let window = NSApplication.shared.mainWindow else {
            NSLog("Screenshot: no main window")
            return
        }

        // Capture the window content (the emulator display area)
        guard let contentView = window.contentView else { return }
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        contentView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let filename = "NorthMac Screenshot \(df.string(from: Date())).png"
        let desktopURL = desktop.appendingPathComponent(filename)

        do {
            try png.write(to: desktopURL)
            NSSound(named: "Grab")?.play()
            NSLog("Screenshot saved: %@", desktopURL.path)

            // Move to Screenshots folder after a delay
            let screenshotsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/Screenshots")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
                let finalURL = screenshotsDir.appendingPathComponent(filename)
                try? FileManager.default.moveItem(at: desktopURL, to: finalURL)
            }
        } catch {
            NSLog("Screenshot failed: %@", error.localizedDescription)
        }
    }
}
