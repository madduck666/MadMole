// swift-tools-version:5.9
//
// MadMole: a native macOS (Apple Silicon) front end for the Mole engine.
// The cleanup engine stays the shell + Go CLI in this repository; the app
// bundles it and drives it, so every safety rule of the CLI still applies.

import PackageDescription

let package = Package(
    name: "MadMole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MadMole", targets: ["MadMole"]),
    ],
    dependencies: [
        // Embedded terminal for actions that need the CLI's own confirmation
        // and administrator prompts. Pinned: 1.11+ adds a Metal resource bundle
        // and benchmark dependencies, and 1.99 needs Swift 6.2.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "MadMole",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/MadMole"
        ),
    ]
)
