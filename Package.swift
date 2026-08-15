// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "dictate",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "dictate", targets: ["dictate"]),
        .library(name: "DictateCore", targets: ["DictateCore"]),
    ],
    targets: [
        .target(name: "DictateCore"),
        .executableTarget(
            name: "dictate",
            dependencies: ["DictateCore"]
        ),
        .testTarget(
            name: "DictateCoreTests",
            dependencies: ["DictateCore"]
        ),
        .testTarget(
            name: "DictateAppTests",
            dependencies: ["dictate"]
        ),
    ]
)
