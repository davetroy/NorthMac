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
            // Replace New Window with our File menu items
            CommandGroup(replacing: .newItem) {
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

                Button("Save Screenshot") {
                    NotificationCenter.default.post(name: .takeScreenshot, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Toggle Turbo") {
                    NotificationCenter.default.post(name: .toggleTurbo, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
            }

            // Remove the default Save item
            CommandGroup(replacing: .saveItem) { }
        }
    }
}
