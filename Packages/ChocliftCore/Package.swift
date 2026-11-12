// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ChocliftCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "ChocliftCore",
            targets: ["ChocliftCore"]
        )
    ],
    targets: [
        .target(
            name: "ChocliftCore",
            path: "Sources/ChocliftCore"
        ),
        .testTarget(
            name: "ChocliftCoreTests",
            dependencies: ["ChocliftCore"],
            path: "Tests/ChocliftCoreTests"
        )
    ]
)
