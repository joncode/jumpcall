// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jumpcall",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "JumpCallKit",
            path: "Sources/JumpCallKit"
        ),
        .executableTarget(
            name: "jumpcall",
            dependencies: ["JumpCallKit"],
            path: "Sources/jumpcall"
        ),
        // Plain assert-based runner instead of XCTest/Swift Testing: the
        // Xcode Command Line Tools ship neither in working form, and this
        // project's promise is "no Xcode required". Run with `make test`.
        .executableTarget(
            name: "JumpCallTests",
            dependencies: ["JumpCallKit"],
            path: "Tests/TestRunner"
        ),
    ]
)
