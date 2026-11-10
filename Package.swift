// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spendthrift",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Spendthrift",
            path: "Sources/Spendthrift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
