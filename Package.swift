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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "FreeTypist",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/FreeTypist",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "FreeTypistTests",
            dependencies: ["FreeTypist"],
            path: "Tests/FreeTypistTests"
        )
    ]
)
