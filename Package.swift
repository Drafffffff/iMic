// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iMicLink",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "iMicLink", targets: ["iMicLink"])
    ],
    targets: [
        .target(name: "iMicLink", path: "shared"),
        .testTarget(
            name: "iMicLinkTests",
            dependencies: ["iMicLink"],
            path: "tests/iMicLinkTests"
        )
    ]
)
