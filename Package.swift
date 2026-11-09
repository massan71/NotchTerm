// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "NotchTerm",
            dependencies: ["SwiftTerm"],
            path: "Sources/NotchTerm"
        ),
        .testTarget(
            name: "NotchTermTests",
            dependencies: ["NotchTerm"],
            path: "Tests/NotchTermTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
