// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeTypist",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "FreeTypist",
            targets: ["FreeTypist"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FreeTypist",
            dependencies: [],
            path: "Sources/FreeTypist"
        ),
        .testTarget(
            name: "FreeTypistTests",
            dependencies: ["FreeTypist"],
            path: "Tests/FreeTypistTests"
        )
    ]
)
