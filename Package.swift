// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "t650",
    targets: [
        // Portable core: decoder + gesture recogniser. Compiles on Linux and macOS.
        .target(name: "T650Kit", path: "Sources/T650Kit"),
        // macOS daemon: IOHIDManager transport + CGEvent output. macOS-only.
        .executableTarget(name: "t650d", dependencies: ["T650Kit"], path: "Sources/t650d"),
        .testTarget(name: "T650KitTests", dependencies: ["T650Kit"], path: "Tests/T650KitTests",
                    resources: [.copy("fixtures")]),
    ]
)
