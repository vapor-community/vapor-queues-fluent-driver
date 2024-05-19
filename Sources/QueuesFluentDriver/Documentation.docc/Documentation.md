# ``QueuesFluentDriver``

@Metadata {
    @TitleHeading("Package")
}

A driver for [Queues]. Uses [Fluent] to store job metadata in an SQL database.

[Queues]: https://github.com/vapor/queues
[Fluent]: https://github.com/vapor/fluent

## Compatibility

This package makes use of the `SKIP LOCKED` feature supported by some of the major database engines (most notably [PostgresSQL][postgres-skip-locked] and [MySQL][mysql-skip-locked]) when available to make a best-effort guarantee that a task or job won't be picked by multiple workers.

This package should be compatible with any SQL database supported by the various Fluent drivers. It is specifically known to work with:

- PostgreSQL 11.0+
- MySQL 5.7+
- MariaDB 10.5+
- SQLite

> [!WARNING]
> Although SQLite can be used with this package, SQLite has no support for advanced locking. It is not likely to function correctly with more than one or two queue workers.

[postgres-skip-locked]: https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE
[mysql-skip-locked]: https://dev.mysql.com/doc/refman/8.4/en/select.html#:~:text=SKIP%20LOCKED%20causes%20a

## Getting started

#### Adding the dependency

Add `QueuesFluentDriver` as dependency to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/vapor-community/vapor-queues-fluent-driver.git", from: "3.0.0-beta.4"),
  ...
]
```

Add `QueuesFluentDriver` to the target you want to use it in:
```swift
targets: [
    .target(
        name: "MyFancyTarget",
        dependencies: [
            .product(name: "QueuesFluentDriver", package: "vapor-queues-fluent-driver"),
            ...
        ]
    ),
]
```

#### Configuration

This package includes a migration to create the database table which holds job metadata; add it to your Fluent configuration as you would any other migration:

```swift
app.migrations.add(JobModelMigration())
```

Finally, load the `QueuesFluentDriver` driver:
```swift    
app.queues.use(.fluent())
```

> Warning: Always call `app.databases.use(...)` **before** calling `app.queues.use(.fluent())`!

## Options

### Using a custom Database 

You can optionally create a dedicated non-default `Database` with a custom `DatabaseID` for use with your queues, as in the following example:

```swift
extension DatabaseID {
    static var queues: Self { .init(string: "my_queues_db") }
}

func configure(_ app: Application) async throws {
    app.databases.use(.postgres(configuration: ...), as: .queues, isDefault: false)
    app.queues.use(.fluent(.queues))
}
```

## Caveats

### Polling interval and number of workers

By default, the Vapor Queues system starts 2 workers per available CPU core, with each worker would polling the database once per second. On a 4-core system, this would results in 8 workers querying the database every second. Most configurations do not need this many workers. Additionally, when using SQLite as the underlying database it is generally inadvisable to run more than one worker at a time, as SQLite does not have the necessary support for cross-connection locking.

The polling interval can be changed using the `refreshInterval` configuration setting:

```swift
app.queues.configuration.refreshInterval = .seconds(5)
```

Likewise, the number of workers to start can be changed via the `workerCount` setting:

```swift
app.queues.configuration.workerCount = 1
```
