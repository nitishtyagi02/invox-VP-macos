// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InvoxPrintAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "InvoxPrintAgent",
            path: "Sources/InvoxPrintAgent"
        )
    ]
)
