// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fettle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fettle", targets: ["Fettle"]),
        .library(name: "FettleCore", targets: ["FettleCore"]),
        .library(name: "FettleUI", targets: ["FettleUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "FettleCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The interface lives in its own library rather than in the executable
        // so its view models can be driven directly from tests. A SwiftUI
        // screen that only ever runs inside the app is a screen whose state
        // machine is never checked.
        .target(
            name: "FettleUI",
            dependencies: [
                "FettleCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Fettle",
            dependencies: [
                "FettleCore",
                "FettleUI",
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
        .testTarget(
            name: "FettleUITests",
            dependencies: ["FettleUI", "FettleCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
