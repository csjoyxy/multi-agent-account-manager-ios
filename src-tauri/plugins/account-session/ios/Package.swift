// swift-tools-version:5.9
// Modified by csjoyxy in 2026 from https://github.com/ldjx7/multi-agent-account-manager (Apache-2.0) for iOS 16.0+ & iOS Group Chat support.
import PackageDescription

let package = Package(
  name: "tauri-plugin-account-session",
  platforms: [
    .iOS(.v16)
  ],
  products: [
    .library(
      name: "tauri-plugin-account-session",
      type: .static,
      targets: ["tauri-plugin-account-session"]
    )
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api")
  ],
  targets: [
    .target(
      name: "tauri-plugin-account-session",
      dependencies: [
        .product(name: "Tauri", package: "Tauri")
      ],
      path: "Sources"
    )
  ]
)
