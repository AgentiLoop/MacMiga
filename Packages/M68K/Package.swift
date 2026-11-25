// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "M68K",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "M68K", targets: ["M68K"])
    ],
    targets: [
        .target(name: "M68K"),
        .testTarget(name: "M68KTests", dependencies: ["M68K"])
    ]
)
