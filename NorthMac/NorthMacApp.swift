import SwiftUI

extension Notification.Name {
    static let toggleTurbo = Notification.Name("toggleTurbo")
    static let takeScreenshot = Notification.Name("takeScreenshot")
    static let mountDisk1 = Notification.Name("mountDisk1")
    static let mountDisk2 = Notification.Name("mountDisk2")
}

@main
struct NorthMacApp: App {
    init() {
        ResourceCache.shared.ensureLoaded {}
        MetalDisplayNSView.precompileShader()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About NorthMac") {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "NorthMac",
                        .applicationVersion: "\(version) (build \(BuildInfo.buildNumber))",
                        .version: "\(BuildInfo.gitHash)",
                        .credits: NSAttributedString(string: "NorthStar Advantage Emulator"),
                    ])
                }
            }

            // Add disk mount items after the default New Window (Cmd+N)
            CommandGroup(after: .newItem) {
                Divider()

                Button("Mount Disk Image...") {
                    NotificationCenter.default.post(name: .mountDisk1, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Mount Disk Image to Drive 2...") {
                    NotificationCenter.default.post(name: .mountDisk2, object: nil)
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
