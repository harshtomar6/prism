// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PRism",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "PRism",
            path: "Sources/PRism"
        )
    ]
)
