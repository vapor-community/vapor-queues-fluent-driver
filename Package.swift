// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "QueuesFluentDriver",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "QueuesFluentDriver", targets: ["QueuesFluentDriver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.1"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.45.1"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.28.0"),
        .package(url: "https://github.com/vapor/queues.git", from: "1.13.0"),
    ],
    targets: [
        .target(
            name: "QueuesFluentDriver",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "Queues", package: "queues")
            ]
        ),
        .testTarget(
            name: "QueuesFluentDriverTests",
            dependencies: [
                .target(name: "QueuesFluentDriver"),
            ]
        ),
    ]
)
