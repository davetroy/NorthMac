// swift-tools-version:5.9
//
// Test harness for the pure-Swift portions of NorthMac. The main app is
// built via NorthMac.xcodeproj — this Package.swift exists solely so the
// disk controllers can be unit-tested with `swift test` from the command
// line, independent of the Xcode app target.
//
// Both FloppyDiskController.swift and HardDiskController.swift import only
// Foundation and have no AppKit / Metal / z80.c dependencies, so SPM can
// compile them in isolation as a library against the test target.

import PackageDescription

let package = Package(
    name: "NorthMacCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "NorthMacCore",
            path: "NorthMac/Core",
            sources: [
                "FloppyDiskController.swift",
                "HardDiskController.swift"
            ]
        ),
        .testTarget(
            name: "NorthMacCoreTests",
            dependencies: ["NorthMacCore"],
            path: "Tests/NorthMacCoreTests"
        )
    ]
)
