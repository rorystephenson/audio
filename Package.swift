// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudIO",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AudIO", path: "Sources/AudIO"),
    ]
)
