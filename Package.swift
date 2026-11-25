// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMiga",
    platforms: [.macOS(.v13)],
    products: [.library(name: "MacMigaCore", targets: ["MacMigaCore"])],
    targets: [
        .target(name: "MacMigaCore"),
        .testTarget(name: "MacMigaCoreTests", dependencies: ["MacMigaCore"])
    ]
)
