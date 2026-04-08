import SwiftUI

extension Notification.Name {
    static let toggleTurbo = Notification.Name("toggleTurbo")
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
                    MetalDisplayNSView.current?.saveScreenshot()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }
}
