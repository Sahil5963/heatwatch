// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HeatWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HeatWatch",
            path: "Sources/HeatWatch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
