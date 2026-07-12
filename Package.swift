// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuadFinder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuadFinder", targets: ["QuadFinder"])
    ],
    targets: [
        .executableTarget(
            name: "QuadFinder",
            path: "Sources/QuadFinder",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "QuadFinderTests",
            dependencies: ["QuadFinder"],
            path: "Tests/QuadFinderTests"
        )
    ]
)
