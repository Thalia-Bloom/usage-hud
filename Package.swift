// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodexUsageHUD",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle 2 auto-updates. `make app` embeds Sparkle.framework in
        // Contents/Frameworks; the rpath below lets the bundled executable find it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageHUD",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "CodexUsageHUDTests",
            dependencies: ["CodexUsageHUD"]
        )
    ]
)
