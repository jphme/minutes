// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Minutes",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Minutes", targets: ["Minutes"]),
        .executable(name: "minutes-cli", targets: ["minutes-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .target(
            name: "MinutesCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Minutes",
            dependencies: ["MinutesCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "minutes-cli",
            dependencies: ["MinutesCore", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
