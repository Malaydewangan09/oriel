import AppKit
import SwiftUI

enum Design: String, CaseIterable, Identifiable {
    case glass, next, classic
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    static var current: Design { Design(rawValue: UserDefaults.standard.string(forKey: Pref.design) ?? "") ?? .glass }
}

// Fixed colours that read the same in every design and appearance. Views never write a colour literal.
enum Swatch {
    static let ink = Color(red: 0.16, green: 0.14, blue: 0.13)
    static let inkSoft = ink.opacity(0.55)
    static let paper = Color(red: 0.985, green: 0.972, blue: 0.950)
    static let cream = Color(red: 1.0, green: 0.98, blue: 0.92)
    static let indigo = Color(red: 0.20, green: 0.28, blue: 0.58)
    static let periwinkle = Color(red: 0.62, green: 0.70, blue: 1.0)
    static let periwinkleLight = Color(red: 0.70, green: 0.78, blue: 1.0)
    static let amber = Color(red: 0.72, green: 0.38, blue: 0.10)
    static let amberLight = Color(red: 1.0, green: 0.74, blue: 0.42)
    static let teal = Color(red: 0.13, green: 0.55, blue: 0.55)
    static let tealLight = Color(red: 0.55, green: 0.85, blue: 0.85)
    static let lavender = Color(red: 0.75, green: 0.65, blue: 1.0)
    static let hairline = Color.black.opacity(0.07)

    static let codeBackground = Color(red: 0.13, green: 0.14, blue: 0.18)
    static let codeText = Color(red: 0.86, green: 0.88, blue: 0.95).opacity(0.8)
    static let textTileLight = Color(red: 0.965, green: 0.965, blue: 0.97)
    static let textTileDark = Color(white: 0.17)
    static let imageBackdrop = Color(red: 0.94, green: 0.93, blue: 0.91)
    static let secret = [Color(red: 0.20, green: 0.16, blue: 0.14), Color(red: 0.32, green: 0.22, blue: 0.16)]
    static let highlighter = NSColor(red: 1, green: 0.86, blue: 0.2, alpha: 1)
    static let accent = Color(red: 0.36, green: 0.42, blue: 0.95)
    static let well = Color.primary.opacity(0.045)

    // Each site gets a stable colour from its name.
    static func gradient(for host: String) -> [Color] {
        let h = Double(abs(host.hashValue % 360)) / 360
        return [
            Color(hue: h, saturation: 0.45, brightness: 0.42),
            Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.40, brightness: 0.62),
        ]
    }
}

// Every colour the shelf uses, for one design and appearance.
struct Palette {
    let shell: Color, raised: Color, paper: Color, line: Color, text: Color, soft: Color, accent: Color, warm: Color, field: Color
    var glassy = false

    // Light catching the top edge of a glass control.
    var rim: LinearGradient {
        LinearGradient(colors: glassy ? [.white.opacity(0.6), .white.opacity(0.06)] : [line, line], startPoint: .top, endPoint: .bottom)
    }

    static func make(_ design: Design, dark: Bool) -> Palette {
        switch (design, dark) {
        // Frosted glass: surfaces are tints over the blurred desktop. Controls float as glass, content stays solid.
        case (.glass, true):
            Palette(
                shell: .clear, raised: Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.82), paper: .black.opacity(0.3), line: .white.opacity(0.1),
                text: .white.opacity(0.95), soft: .white.opacity(0.62), accent: Swatch.periwinkleLight,
                warm: Color(red: 1.0, green: 0.78, blue: 0.48),
                field: .white.opacity(0.1), glassy: true)
        case (.glass, false):
            Palette(
                shell: .clear, raised: .white.opacity(0.85), paper: .white.opacity(0.7), line: .black.opacity(0.06), text: Swatch.ink,
                soft: Swatch.ink.opacity(0.6), accent: Swatch.indigo, warm: Swatch.amber, field: .white.opacity(0.4), glassy: true)
        case (.next, true):
            Palette(
                shell: Color(red: 0.055, green: 0.055, blue: 0.065), raised: Color(red: 0.11, green: 0.11, blue: 0.125),
                paper: Color(red: 0.14, green: 0.12, blue: 0.10),
                line: .white.opacity(0.08), text: .white.opacity(0.92), soft: .white.opacity(0.48), accent: Swatch.periwinkle,
                warm: Swatch.amberLight, field: .white.opacity(0.07))
        case (.next, false):
            Palette(
                shell: Swatch.paper, raised: .white, paper: Swatch.cream, line: .black.opacity(0.08), text: Swatch.ink, soft: Swatch.inkSoft,
                accent: Swatch.indigo, warm: Swatch.amber, field: .black.opacity(0.05))
        case (.classic, true):
            Palette(
                shell: .black, raised: .white, paper: Swatch.cream, line: .clear, text: .white.opacity(0.92), soft: .white.opacity(0.5),
                accent: Swatch.periwinkle, warm: Swatch.amberLight, field: .white.opacity(0.1))
        case (.classic, false):
            Palette(
                shell: Swatch.paper, raised: .white, paper: Swatch.cream, line: .black.opacity(0.08), text: Swatch.ink, soft: Swatch.inkSoft,
                accent: Swatch.indigo, warm: Swatch.amber, field: .black.opacity(0.05))
        }
    }
}
