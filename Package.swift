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
            // Everything in the repo that is not one of `sources` below. The two
            // `sevo-engine-*.tar.xz` payloads are named for the engine revision they carry, so a
            // fresh `Tools/package-engine.sh` run adds a name this list has to learn.
            exclude: [
                "CONTRIBUTING.md",
                "DELETE-CANDIDATES.md",
                "default.profraw",
                "Docs",
                "HANDOFF.md",
                "LICENSE",
                "Mockups",
                "README.md",
                "Sevoflurane.xcodeproj",
                "Sevoflurane/App",
                "Sevoflurane/Assets.xcassets",
                "Sevoflurane/Bridge/BridgeJS.swift",
                "Sevoflurane/Bridge/HTTPServer.swift",
                "Sevoflurane/Bridge/SteamBridge.swift",
                "Sevoflurane/Bridge/WebSocketServer.swift",
                "Sevoflurane/Bridge/steamclient_shim.js",
                "Sevoflurane/Info.plist",
                "Sevoflurane/Setup/GPTkDownload.swift",
                "Sevoflurane/Setup/GPTkDownloadPanel.swift",
                "Sevoflurane/Setup/GPTkEngineInstaller.swift",
                "Sevoflurane/Setup/SetupDryRun.swift",
                "Sevoflurane/Setup/SetupView.swift",
                "Sevoflurane/Sevoflurane.icon",
                "Sevoflurane/Support/AgentIntegration.swift",
                "Sevoflurane/Support/BottleDependencies.swift",
                "Sevoflurane/Support/HostSnapshot.swift",
                "Sevoflurane/Support/MainThreadHop.swift",
                "Sevoflurane/Support/MainThreadWatchdog.swift",
                "Sevoflurane/Support/SharedGames.swift",
                "Sevoflurane/Support/SteamScreenSpace.swift",
                "Sevoflurane/Support/SyntheticLoad.swift",
                "Sevoflurane/Support/WineWindowWatch.swift",
                "Sevoflurane/Web",
                "SevofluraneTests",
                "Site",
                "Spike",
                "Tools",
                "sevo-engine-sevo-r1c-wine11.16.tar.xz",
                "sevo-engine-sevo-r1d-wine11.16.tar.xz",
                "sevo-engine-wine11.16-dxmt0.80-r1.tar.xz",
            ],
            sources: [
                "Sevo",
                "Sevoflurane/Bridge/CDPClient.swift",
                "Sevoflurane/Setup/D3DMetalInstaller.swift",
                "Sevoflurane/Setup/EngineInstaller.swift",
                "Sevoflurane/Setup/EngineManifest.swift",
                "Sevoflurane/Setup/Provisioner.swift",
                "Sevoflurane/Setup/SetupEnvironment.swift",
                "Sevoflurane/Setup/SetupLog.swift",
                "Sevoflurane/Setup/SetupDetection.swift",
                "Sevoflurane/Support/BottleGraphics.swift",
                "Sevoflurane/Support/BridgePorts.swift",
                "Sevoflurane/Support/ClientLifecycle.swift",
                "Sevoflurane/Support/CrossOverShadow.swift",
                "Sevoflurane/Support/Engine.swift",
                "Sevoflurane/Support/EngineRenderers.swift",
                "Sevoflurane/Support/GPUEquivalence.swift",
                "Sevoflurane/Support/GPUIdentity.swift",
                "Sevoflurane/Support/JSLiteral.swift",
                "Sevoflurane/Support/PerformanceProbes.swift",
                "Sevoflurane/Support/Preferences.swift",
                "Sevoflurane/Support/SteamBottle.swift",
                "Sevoflurane/Support/SteamChatAutoOpen.swift",
                "Sevoflurane/Support/SteamMessageSound.swift",
                "Sevoflurane/Support/StorageInventory.swift",
                "Sevoflurane/Support/SteamWebCookie.swift",
                "Sevoflurane/Support/Subprocess.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
        ),
    ],
)
