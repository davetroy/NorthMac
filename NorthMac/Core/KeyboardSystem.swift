import Foundation
import AppKit
import Carbon.HIToolbox

/// Maps macOS key events to NorthStar Advantage 7-bit ASCII
struct KeyboardSystem {
    /// Convert a macOS key event to a 7-bit ASCII character
    static func mapKey(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> UInt8? {
        // Use the character string directly for most keys
        guard let char = characters.first else { return nil }
        let ascii = char.asciiValue

        // Handle control key combinations
        if modifiers.contains(.control) {
            if let a = ascii {
                if a >= 0x40 && a <= 0x7F {
                    return a & 0x1F  // Ctrl+letter -> control code
                }
                if a >= 0x60 && a <= 0x7F {
                    return a & 0x1F
                }
            }
        }

        // Special keys
        switch Int(keyCode) {
        case kVK_Return:       return 0x0D
        case kVK_Tab:          return 0x09
        case kVK_Delete:       return 0x08  // Backspace
        case kVK_ForwardDelete: return 0x7F
        case kVK_Escape:       return 0x1B
        case kVK_UpArrow:      return 0x0B  // VT
        case kVK_DownArrow:    return 0x0A  // LF
        case kVK_LeftArrow:    return 0x08  // BS
        case kVK_RightArrow:   return 0x0C  // FF
        default: break
        }

        // Standard ASCII range
        if let a = ascii, a < 0x80 {
            return a
        }

        return nil
    }
}
