// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hoatzin",
    // iOS only for HoatzinCore: the code a future iOS app shares with the Mac app.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HoatzinCore", targets: ["HoatzinCore"]),
        .library(name: "HoatzinUI", targets: ["HoatzinUI"]),
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
        // SwiftUI views both apps show the same way (the graphs of Proxmox nodes and guests).
        .target(
            name: "HoatzinUI",
            dependencies: ["HoatzinCore"],
            path: "Sources/HoatzinUI"
        ),
        .executableTarget(
            name: "Hoatzin",
            dependencies: ["HoatzinCore", "HoatzinUI", .product(name: "SwiftTerm", package: "SwiftTerm")],
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
