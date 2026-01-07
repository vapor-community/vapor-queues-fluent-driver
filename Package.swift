// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "queues-fluent-driver",
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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.53.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.34.0"),
        .package(url: "https://github.com/vapor/queues.git", from: "1.17.2"),
        .package(url: "https://github.com/vapor/console-kit.git", from: "4.15.2"),
        .package(url: "https://github.com/vapor-community/sql-kit-extras.git", from: "0.0.9"),
    ] + (Context.environment["CI"] != nil ? [
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.1"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        .package(url: "https://github.com/vapor/fluent-mysql-driver.git", from: "4.8.0"),
    ] : []),
    targets: [
        .target(
            name: "QueuesFluentDriver",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "SQLKitExtras", package: "sql-kit-extras"),
                .product(name: "Queues", package: "queues")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "QueuesFluentDriverTests",
            dependencies: [
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "ConsoleKitTerminal", package: "console-kit"),
                .target(name: "QueuesFluentDriver"),
            ] + (Context.environment["CI"] != nil ? [
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
            ] : []),
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
    // .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    // .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
] }
