import Foundation

/// Parses argv into a set of disk-image URLs the app should mount at launch.
///
/// Usage: `northmac [--auto-enter] disk1.nsi [disk2.nsi] [hd.nhd]`
/// - First `.nsi` → floppy drive 0
/// - Second `.nsi` → floppy drive 1
/// - First `.nhd` → hard disk
/// - `--auto-enter` → automatically press Return at `LOAD SYSTEM` once
///   the prompt appears. Off by default; intended for headless/automated
///   testing where no human is at the keyboard.
/// - Relative paths are resolved against the launch CWD.
/// - Tilde expansion is supported.
/// - Unrecognized args starting with `-` (e.g. `-NSDocumentRevisionsDebugMode`,
///   `-psn_…`) are ignored.
enum CLILaunchArgs {
    struct Parsed: Equatable {
        var floppy0: URL?
        var floppy1: URL?
        var hardDisk: URL?
        var autoEnter: Bool = false

        var hasAny: Bool { floppy0 != nil || floppy1 != nil || hardDisk != nil }
    }

    /// Returns parsed launch args, or nil if no recognized disk-image files were supplied.
    static func parse(_ argv: [String] = CommandLine.arguments,
                      cwd: String = FileManager.default.currentDirectoryPath) -> Parsed? {
        var p = Parsed()
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)

        for arg in argv.dropFirst() {
            if arg == "--auto-enter" {
                p.autoEnter = true
                continue
            }
            if arg.hasPrefix("-") { continue }  // ignore unknown flags + Cocoa boilerplate

            let url = resolve(arg, relativeTo: cwdURL)
            switch url.pathExtension.uppercased() {
            case "NSI":
                if p.floppy0 == nil { p.floppy0 = url }
                else if p.floppy1 == nil { p.floppy1 = url }
                else { NSLog("northmac: ignoring extra floppy image: %@", arg) }
            case "NHD":
                if p.hardDisk == nil { p.hardDisk = url }
                else { NSLog("northmac: ignoring extra hard disk image: %@", arg) }
            default:
                NSLog("northmac: ignoring unrecognized file: %@", arg)
            }
        }
        return p.hasAny ? p : nil
    }

    private static func resolve(_ path: String, relativeTo cwd: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
    }
}
