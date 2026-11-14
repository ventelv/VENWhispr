// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VENWhispr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VENWhispr",
            path: "Sources/VENWhispr"
        )
    ]
)
