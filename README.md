# QueuesFluentDriver

A driver for [Queues]. Uses [Fluent] to store job metadata in an SQL database.

[Queues]: https://github.com/vapor/queues
[Fluent]: https://github.com/vapor/fluent

## Compatibility

This package makes use of the `SKIP LOCKED` feature supported by some of the major database engines (most notably [PostgresSQL][postgres-skip-locked] and [MySQL][mysql-skip-locked]) when available to make a best-effort guarantee that a task or job won't be picked by multiple workers.

This package should be compatible with:

- PostgreSQL 11.0+
- MySQL 8.0+
- MariaDB 10.5+

> [!NOTE]
> Although SQLite can be used with this package, SQLite has no support for advanced locking. It is not likely to function correctly with more than one or two queue workers.

[postgres-skip-locked]: https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE
[mysql-skip-locked]: https://dev.mysql.com/doc/refman/8.3/en/select.html#:~:text=SKIP%20LOCKED%20causes%20a

## Getting started

#### Adding the dependency

Add `QueuesFluentDriver` as dependency to your `Package.swift`:

```swift
  dependencies: [
    .package(url: "https://github.com/vapor-community/vapor-queues-fluent-driver.git", from: "3.0.0-beta.2"),
    ...
  ]
```

Add `QueuesFluentDriver` to the target you want to use it in:
```swift
  targets: [
    .target(name: "MyFancyTarget", dependencies: [
      .product(name: "QueuesFluentDriver", package: "vapor-queues-fluent-driver"),
    ])
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

> [!WARNING]
> Always call `app.databases.use(...)` **before** calling `app.queues.use(.fluent())`!

## Options

### Using a custom Database 
You can optionally create a dedicated Database, set to `isdefault: false` and with a custom `DatabaseID` and use it for your Queues.
In that case you would initialize the Queues configuration like this:

```swift
let queuesDb = DatabaseID(string: "my_queues_db")
app.databases.use(.postgres(configuration: dbConfig), as: queuesDb, isDefault: false)
app.queues.use(.fluent(queuesDb))
```

### Customizing the jobs table name
You can customize the name of the table used by this driver during the migration :
```swift
app.migrations.add(JobMetadataMigrate(schema: "my_jobs"))
```

## Caveats

### Polling interval and number of workers

By default, the Vapor Queues system starts 2 workers per available CPU core, with each worker would polling the database once per second. On a 4-core system, this would results in 8 workers querying the database every second. Most configurations do not need this many workers.

The polling interval can be changed using the `refreshInterval` configuration setting:

```swift
app.queues.configuration.refreshInterval = .seconds(5)
```

Likewise, the number of workers to start can be changed via the `workerCount` setting:

```swift
app.queues.configuration.workerCount = 1
```
