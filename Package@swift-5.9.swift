// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QueuesFluentDriver",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "QueuesFluentDriver", targets: ["QueuesFluentDriver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.100.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.10.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.48.4"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.30.0"),
        .package(url: "https://github.com/vapor/queues.git", from: "1.15.0"),
        //.package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.7.1"),
        //.package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.1"),
        //.package(url: "https://github.com/vapor/fluent-mysql-driver.git", from: "4.5.0"),
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
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "QueuesFluentDriverTests",
            dependencies: [
                .product(name: "XCTVapor", package: "vapor"),
                //.product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                //.product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                //.product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .target(name: "QueuesFluentDriver"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ForwardTrailingClosures"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableExperimentalFeature("StrictConcurrency=complete"),
] }
