// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeshHessen",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.28.0"
        ),
        .package(
            url: "https://github.com/armadsen/ORSSerialPort.git",
            from: "2.1.0"
        ),
    ],
    targets: [
        .target(
            name: "MeshHessen",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ORSSerial", package: "ORSSerialPort"),
            ],
            path: "MeshHessen",
            exclude: [
                "Assets.xcassets",
                "MeshHessen.entitlements",
                "MeshHessen.xcdatamodeld",   // CoreData model: compiled by Xcode, not SPM
                "Proto",
                "Resources",
                "MeshHessenApp.swift",       // @main — excluded so test binary can link
            ]
        ),
        .testTarget(
            name: "MeshHessenTests",
            dependencies: ["MeshHessen"],
            path: "Tests/MeshHessenTests"
        ),
    ]
)
