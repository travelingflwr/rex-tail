// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RexWidgets",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "RexWidgets",
            path: "Sources/RexWidgets",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
