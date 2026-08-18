// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MixDictate",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MixDictate", path: "Sources/MixDictate")
    ]
)
