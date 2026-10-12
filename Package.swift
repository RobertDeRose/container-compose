// swift-tools-version: 6.2
import PackageDescription

// Linux runs the portable ownership, reply-waiting, and guest-script tests only.
// The executable and Apple client libraries require macOS.
#if os(macOS)
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/container.git", revision: "eee7ad097079cc3b02d5309ec10160143f2d0c6a"),
    .package(url: "https://github.com/apple/containerization.git", exact: "0.43.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.14.0"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.7.4"),
]
let appleProducts: [Target.Dependency] = [
    .product(name: "ContainerAPIClient", package: "container"),
    .product(name: "ContainerPersistence", package: "container"),
    .product(name: "ContainerResource", package: "container"),
    .product(name: "ContainerVersion", package: "container"),
    .product(name: "ContainerXPC", package: "container"),
    .product(name: "MachineAPIClient", package: "container"),
    .product(name: "TerminalProgress", package: "container"),
    .product(name: "Containerization", package: "containerization"),
    .product(name: "ContainerizationExtras", package: "containerization"),
    .product(name: "ContainerizationOCI", package: "containerization"),
    .product(name: "ContainerizationOS", package: "containerization"),
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
    .product(name: "Logging", package: "swift-log"),
    .product(name: "SystemPackage", package: "swift-system"),
]
let products: [Product] = [.executable(name: "compose", targets: ["compose"])]
let platformTargets: [Target] = [
    .target(name: "ContainerCompose", dependencies: appleProducts + ["ComposeSupport"]),
    .executableTarget(name: "compose", dependencies: ["ContainerCompose"], path: "Sources/ComposePlugin"),
    .testTarget(name: "ComposePluginTests", dependencies: appleProducts + ["ContainerCompose", "ComposeSupport"]),
]
#else
let dependencies: [Package.Dependency] = []
let products: [Product] = []
let platformTargets: [Target] = []
#endif

let package = Package(
    name: "container-compose",
    platforms: [.macOS("15")],
    products: products,
    dependencies: dependencies,
    targets: [
        .target(name: "ComposeSupport"),
        .testTarget(name: "ComposeSupportTests", dependencies: ["ComposeSupport"]),
    ] + platformTargets
)
