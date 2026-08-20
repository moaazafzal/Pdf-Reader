// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AquaPDF",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AquaPDF",
            path: "Sources/AquaPDF",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
