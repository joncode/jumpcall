// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jumpcall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "jumpcall",
            path: "Sources/jumpcall"
        )
    ]
)
