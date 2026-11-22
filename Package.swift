// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hoatzin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hoatzin", targets: ["Hoatzin"]),
        .executable(name: "hoatzin-askpass", targets: ["hoatzin-askpass"]),
        .executable(name: "hoatzin-mcp", targets: ["hoatzin-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Hoatzin",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Hoatzin"
        ),
        .executableTarget(
            name: "hoatzin-askpass",
            path: "Sources/hoatzin-askpass"
        ),
        .executableTarget(
            name: "hoatzin-mcp",
            path: "Sources/hoatzin-mcp"
        ),
        .testTarget(
            name: "HoatzinTests",
            dependencies: ["Hoatzin", "hoatzin-askpass", "hoatzin-mcp"],
            path: "Tests/HoatzinTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
