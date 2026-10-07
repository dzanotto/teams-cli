// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "teams-cli",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "teams-cli", targets: ["TeamsCLI"])],
    targets: [
        .target(name: "TeamsCore"),
        .executableTarget(name: "TeamsCLI", dependencies: ["TeamsCore"]),
        .testTarget(name: "TeamsCoreTests", dependencies: ["TeamsCore"]),
        .testTarget(name: "TeamsCLITests", dependencies: ["TeamsCLI", "TeamsCore"])
    ]
)
