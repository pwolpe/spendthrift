// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Appauled",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Appauled",
            path: "Sources/Appauled",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
