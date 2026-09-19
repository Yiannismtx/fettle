// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fettle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fettle", targets: ["Fettle"]),
        .library(name: "FettleCore", targets: ["FettleCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "FettleCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Fettle",
            dependencies: [
                "FettleCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "FettleCoreTests",
            dependencies: ["FettleCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
