// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kestrel",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Kestrel",
            path: "Sources/Kestrel"
        )
    ]
)
