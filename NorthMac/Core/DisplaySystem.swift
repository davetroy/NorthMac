import Foundation

enum PhosphorColor: String, CaseIterable {
    case green = "Green"
    case amber = "Amber"
    case white = "White"
}

/// Display configuration (phosphor color selection, dimensions)
final class DisplaySystem {
    static let width = 640    // 80 columns * 8 pixels/byte
    static let height = 240   // 240 visible scanlines

    var phosphor: PhosphorColor = .green
}
