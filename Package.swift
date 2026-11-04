// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sill",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Sill", linkerSettings: [.linkedLibrary("sqlite3")])],
    swiftLanguageModes: [.v5]
)
