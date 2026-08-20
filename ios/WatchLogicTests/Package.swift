// swift-tools-version:5.9
import PackageDescription

// Unit tests for the watch wire's decision logic.
//
// A package rather than an Xcode unit-test bundle, deliberately. A watchOS test
// target needs a host app, a simulator and a signing identity, and adding one
// means hand-editing a project file this branch has already had to correct once
// for build-phase ordering — all to test code that depends on none of it.
// `WatchWireRules` and the payload models are Foundation-only, so `swift test`
// exercises them on any toolchain, with no Xcode project involved at all.
//
// `Sources/WatchWire/MeshMapperWatchPayload.swift` is a symlink to the shipping
// file in `ios/Shared`, which SwiftPM requires to live under the package root.
// A symlink rather than a copy so there is nothing to drift: the tests compile
// the same bytes the app targets do.
let package = Package(
  name: "WatchLogicTests",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "WatchWire"),
    .testTarget(name: "WatchLogicTests", dependencies: ["WatchWire"]),
  ]
)
