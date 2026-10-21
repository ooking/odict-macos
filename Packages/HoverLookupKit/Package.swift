// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HoverLookupKit",
    platforms: [.macOS(.v12)],
    products: [.library(name: "HoverLookupKit", targets: ["HoverLookupKit"])],
    targets: [
        .target(name: "HoverLookupKit"),
        .testTarget(name: "HoverLookupKitTests", dependencies: ["HoverLookupKit"]),
    ]
)
