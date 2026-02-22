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
            ]
        ),
    ]
)
