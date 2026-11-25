// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMiga",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacMigaCore", targets: ["MacMigaCore"]),
        .executable(name: "MacMiga", targets: ["MacMiga"])
    ],
    dependencies: [
        .package(path: "Packages/M68K")
    ],
    targets: [
        .target(name: "MacMigaCore", dependencies: ["M68K"]),
        .executableTarget(name: "MacMiga", dependencies: ["MacMigaCore"]),
        .executableTarget(name: "KickstartProbe", dependencies: ["MacMigaCore"], path: "Tools"),
        .executableTarget(name: "MakeHardfile", dependencies: ["MacMigaCore"]),
        .testTarget(name: "MacMigaCoreTests", dependencies: ["MacMigaCore"], resources: [.copy("Fixtures")])
    ]
)
