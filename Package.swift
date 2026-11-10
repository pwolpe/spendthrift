// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TonyAwards",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "TonyAwards",
            path: "Sources/TonyAwards",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
