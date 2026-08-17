// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionShelf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SessionShelf", targets: ["SessionShelf"]),
        .library(name: "SessionShelfCore", targets: ["SessionShelfCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite3", path: "Sources/CSQLite3"),
        .target(name: "SessionShelfCore", dependencies: ["CSQLite3"]),
        .executableTarget(
            name: "SessionShelf",
            dependencies: ["SessionShelfCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SessionShelfChecks",
            dependencies: ["SessionShelfCore", "CSQLite3"],
            path: "Tests/SessionShelfChecks"
        ),
        .testTarget(
            name: "SessionShelfTests",
            dependencies: ["SessionShelf"]
        )
    ]
)
