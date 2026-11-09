// swift-tools-version: 6.0
//
// DIXKit: the engine of the next Disk Inventory X, as testable libraries plus
// command-line tools. See DESIGN.md.
//
//   DIXCore            snapshot data model + .dixsnap file format (shared contract)
//   DIXScan            fast parallel scanner producing a Snapshot
//   DIXTreemap         treemap layout + original-style cushion rendering
//   dix-scan           CLI: scan a folder, save a .dixsnap, print stats/timings
//   dix-render         CLI: render a .dixsnap to PNG (iterate on visuals offline)
//   dix-render-reference CLI: render a .dixsnap with the ORIGINAL app's treemap code
//
import PackageDescription

let package = Package(
    name: "DIXKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DIXCore", targets: ["DIXCore"]),
        .library(name: "DIXScan", targets: ["DIXScan"]),
        .library(name: "DIXTreemap", targets: ["DIXTreemap"]),
        .executable(name: "dix-scan", targets: ["dix-scan"]),
        .executable(name: "dix-render", targets: ["dix-render"]),
        .executable(name: "dix-render-reference", targets: ["dix-render-reference"]),
    ],
    targets: [
        .target(name: "DIXCore"),
        .target(name: "DIXScan", dependencies: ["DIXCore"]),
        .target(name: "DIXTreemap", dependencies: ["DIXCore"]),
        .executableTarget(name: "dix-scan", dependencies: ["DIXCore", "DIXScan"]),
        .executableTarget(name: "dix-render", dependencies: ["DIXCore", "DIXTreemap"]),
        // vendored original code (Swift 5 mode, unchanged) + DIXTreemap for fixtures and PNG output
        .executableTarget(name: "dix-render-reference", dependencies: ["DIXCore", "DIXTreemap"],
                          swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-suppress-warnings"])]),
        .testTarget(name: "DIXCoreTests", dependencies: ["DIXCore"]),
        .testTarget(name: "DIXScanTests", dependencies: ["DIXScan", "DIXCore"]),
        .testTarget(name: "DIXTreemapTests", dependencies: ["DIXTreemap", "DIXCore"]),
    ]
)
