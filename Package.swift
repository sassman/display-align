// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DisplayAlign",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DisplayAlign",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "DisplayAlignTests",
            dependencies: ["DisplayAlign"],
            path: "Tests/DisplayAlignTests"
        ),
    ]
)
