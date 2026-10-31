// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IKeyCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "IKeyCore", targets: ["IKeyCore"])],
    targets: [
        .target(name: "IKeyCore"),
        .testTarget(name: "IKeyCoreTests", dependencies: ["IKeyCore"])
    ]
)
