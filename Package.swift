// swift-tools-version: 6.2
import PackageDescription

// ALL targets compile in Swift 5 language mode on purpose. The engine is a
// classic Combine-era ObservableObject that intentionally hops queues
// (detached launch tasks, a GCD process reaper, dispatch-published state);
// Swift 5 mode keeps concurrency checking pragmatic there (warnings, not
// errors). Migrating the pipeline to strict-Swift-6 isolation is the
// natural v2 refactor — not worth the churn while the launcher API is
// brand new.
let package = Package(
    name: "Blocky",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "BlockyKit",
            path: "Sources/BlockyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Blocky",
            dependencies: ["BlockyKit"],
            path: "Sources/Blocky",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BlockyKitTests",
            dependencies: ["BlockyKit"],
            path: "Tests/BlockyKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
