// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TMflash",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TMflash", targets: ["TMflash"]),
        .executable(name: "tmflash-cli", targets: ["tmflash-cli"]),
    ],
    targets: [
        // Everything that talks to hardware or tools: ports, build, esptool,
        // the node's serial console. The app and the CLI are thin shells on it.
        .target(name: "TMflashCore", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]),
        .executableTarget(name: "TMflash", dependencies: ["TMflashCore"]),
        .executableTarget(name: "tmflash-cli", dependencies: ["TMflashCore"]),
        .testTarget(name: "TMflashCoreTests", dependencies: ["TMflashCore"]),
    ]
)
