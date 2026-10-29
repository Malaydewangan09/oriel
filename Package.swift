// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Oriel",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Oriel", linkerSettings: [.linkedLibrary("sqlite3")])],
    swiftLanguageModes: [.v5]
)
