// swift-tools-version: 6.2

// `sevo` — the CLI + MCP server from Docs/cli-mcp-spec.md. One executable
// target that compiles the CLI sources in Sevo/ together with the app's own
// shared source files (lifecycle, CDP client, detections), so the CLI and the
// app cannot drift: same files, two build products. The app itself still
// builds from Sevoflurane.xcodeproj; this package is only how `sevo` builds.
import PackageDescription

let package = Package(
    name: "sevo",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "sevo",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: ".",
            exclude: [
                "CONTRIBUTING.md",
                "Docs",
                "HANDOFF.md",
                "LICENSE",
                "Mockups",
                "README.md",
                "SPEC.md",
                "Sevoflurane.xcodeproj",
                "Sevoflurane/App",
                "Sevoflurane/Assets.xcassets",
                "Sevoflurane/Bridge/BridgeJS.swift",
                "Sevoflurane/Bridge/HTTPServer.swift",
                "Sevoflurane/Bridge/SteamBridge.swift",
                "Sevoflurane/Bridge/WebSocketServer.swift",
                "Sevoflurane/Bridge/steamclient_shim.js",
                "Sevoflurane/Info.plist",
                "Sevoflurane/Sevoflurane.icon",
                "Sevoflurane/Setup/Provisioner.swift",
                "Sevoflurane/Setup/SetupDryRun.swift",
                "Sevoflurane/Setup/SetupEnvironment.swift",
                "Sevoflurane/Setup/SetupView.swift",
                "Sevoflurane/Support/PerformanceProbes.swift",
                "Sevoflurane/Support/SteamScreenSpace.swift",
                "Sevoflurane/Support/WineWindowWatch.swift",
                "Sevoflurane/Web",
                "SevofluraneTests",
                "Site",
                "Spike",
            ],
            sources: [
                "Sevo",
                "Sevoflurane/Bridge/CDPClient.swift",
                "Sevoflurane/Setup/EngineInstaller.swift",
                "Sevoflurane/Setup/EngineManifest.swift",
                "Sevoflurane/Setup/SetupDetection.swift",
                "Sevoflurane/Support/BottleGraphics.swift",
                "Sevoflurane/Support/BridgePorts.swift",
                "Sevoflurane/Support/ClientLifecycle.swift",
                "Sevoflurane/Support/Engine.swift",
                "Sevoflurane/Support/JSLiteral.swift",
                "Sevoflurane/Support/SteamBottle.swift",
                "Sevoflurane/Support/Subprocess.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
        ),
    ],
)
