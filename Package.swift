// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "DiskInventoryXs",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "DiskInventoryXs", targets: ["DiskInventoryXs"])
  ],
  targets: [
    .executableTarget(
      name: "DiskInventoryXs",
      path: "DiskInventoryX",
      exclude: [
        "Assets.xcassets",
        "BuildRelease.sh",
        "DiskInventoryX.entitlements",
        "DiskInventoryX.xcodeproj",
        "Info.plist",
        "build",
      ]
    ),
    .testTarget(
      name: "DiskInventoryCoreTests",
      dependencies: ["DiskInventoryXs"]
    ),
  ]
)
