// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hoatzin",
    // iOS only for HoatzinCore: the code a future iOS app shares with the Mac app.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HoatzinCore", targets: ["HoatzinCore"]),
        .executable(name: "Hoatzin", targets: ["Hoatzin"]),
        .executable(name: "hoatzin-askpass", targets: ["hoatzin-askpass"]),
        .executable(name: "hoatzin-mcp", targets: ["hoatzin-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.4"),
    ],
    targets: [
        // Library model, iCloud sync, Proxmox API and Keychain: no AppKit, builds for iOS too.
        .target(
            name: "HoatzinCore",
            path: "Sources/HoatzinCore"
        ),
        .executableTarget(
            name: "Hoatzin",
            dependencies: ["HoatzinCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
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
            dependencies: ["HoatzinCore", "Hoatzin", "hoatzin-askpass", "hoatzin-mcp"],
            path: "Tests/HoatzinTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
