import SwiftUI

// User settings, in one place. Read anywhere, edited in the Settings window.
enum Pref {
    static let keepDays = "keepDays"  // 0 means forever
    static let peek = "peekEnabled"
    static let secretGuard = "secretGuard"
    static let autoCleanLinks = "autoCleanLinks"
    static let excludedApps = "excludedApps"  // comma-separated app names
    static let design = "design"  // a Design raw value
    static let quickPaste = "quickPaste"  // Option-V paste list
    static let collectInto = "collectInto"  // manual stack row id new copies go into, while "Collect here" is on
    static let collectName = "collectName"
    static let claudeTerminal = "claudeTerminal"  // bundle id of the terminal Claude sessions open in
    static let claudeFolders = "claudeFolders"  // repo name to the folder Claude works in
    static let appearance = "appearance"  // an Appearance raw value

    static func register() {
        UserDefaults.standard.register(defaults: [
            keepDays: 30, peek: true, secretGuard: true, autoCleanLinks: false, design: Design.glass.rawValue, quickPaste: true,
            excludedApps: "1Password,Keychain Access,Passwords,Bitwarden",
        ])
    }
    static var excluded: Set<String> {
        Set(
            (UserDefaults.standard.string(forKey: excludedApps) ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty })
    }
}

// Light, Dark, or follow the Mac. Stored once, read by every shelf view.
enum Appearance: String, CaseIterable, Identifiable {
    case auto = "Auto", light = "Light", dark = "Dark"
    var id: String { rawValue }

    func isDark(_ scheme: ColorScheme) -> Bool { self == .dark || (self == .auto && scheme == .dark) }
}
