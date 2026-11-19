// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoundaryLint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "boundary-lint", targets: ["boundary-lint"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        .target(
            name: "BoundaryLintCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
        ),
        .executableTarget(name: "boundary-lint", dependencies: ["BoundaryLintCore"]),
        .testTarget(name: "BoundaryLintTests", dependencies: ["BoundaryLintCore"]),
    ],
)
