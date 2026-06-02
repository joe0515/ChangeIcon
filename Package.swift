// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChangeIcon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ChangeIcon", targets: ["ChangeIcon"])
    ],
    targets: [
        .executableTarget(
            name: "ChangeIcon",
            path: "Sources"
        )
    ]
)
