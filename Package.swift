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
        .target(name: "SessionShelfCore"),
        .executableTarget(
            name: "SessionShelf",
            dependencies: ["SessionShelfCore"]
        ),
        .executableTarget(
            name: "SessionShelfChecks",
            dependencies: ["SessionShelfCore"],
            path: "Tests/SessionShelfChecks"
        )
    ]
)
