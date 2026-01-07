# QueuesFluentDriver

A driver for [Queues]. Uses [Fluent] to store job metadata in an SQL database.

[Queues]: https://github.com/vapor/queues
[Fluent]: https://github.com/vapor/fluent

## Compatibility

This package makes use of the `SKIP LOCKED` feature supported by some of the major database engines (most notably [PostgresSQL][postgres-skip-locked] and [MySQL][mysql-skip-locked]) when available to make a best-effort guarantee that a job won't be picked up by multiple workers.

This package should be compatible with any SQL database supported by the various Fluent drivers. It is specifically known to work with:

- PostgreSQL 11.0+
- MySQL 5.7+
- MariaDB 10.5+
- SQLite

> [!WARNING]
> Although SQLite can be used with this package, SQLite has no support for advanced locking. It is not likely to function correctly with more than one or two queue workers.

[postgres-skip-locked]: https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE
[mysql-skip-locked]: https://dev.mysql.com/doc/refman/9.5/en/select.html#:~:text=SKIP%20LOCKED%20causes%20a

## Getting started

#### Adding the dependency

Add `QueuesFluentDriver` to your `Package.swift` as a dependency:

```swift
  dependencies: [
    .package(url: "https://github.com/vapor-community/vapor-queues-fluent-driver.git", from: "3.0.0"),
    ...
  ]
```

Then add `QueuesFluentDriver` to the target you want to use it in:
```swift
  targets: [
    .target(name: "MyFancyTarget", dependencies: [
      .product(name: "QueuesFluentDriver", package: "vapor-queues-fluent-driver"),
    ])
  ]
```

Or use SwiftPM's dependency management commands:

```
swift package add-dependency 'https://github.com/vapor-community/vapor-queues-fluent-driver.git' --from '3.0.0'
swift package add-target-dependency --package vapor-queues-fluent-driver QueuesFluentDriver MyFancyTarget
```

#### Configuration

This package includes a migration to create the database table which holds job metadata. Add it to your Fluent configuration as you would any other migration:

```swift
app.migrations.add(JobModelMigration())
```

If you were previously a user of the 1.x or 2.x releases of this driver and have an existing job metadata table in the old data format, you can use `JobModelOldFormatMigration` instead to transparently upgrade the old table to the new format:

```swift
app.migrations.add(JobModelOldFormatMigration())
```

> [!IMPORTANT]
> Use only one or the other of the two migrations; do _not_ use both, and do not change which one you use once one of them has been run.

Finally, load the `QueuesFluentDriver` driver:
```swift    
app.queues.use(.fluent())
```

## Options

The `.fluent()` driver method accepts several configuration options.

### Using a custom DatabaseID

The driver may be configured with a `DatabaseID` other than the default to use for queue operations. The default of `nil` corresponds to Fluent's default database. The database ID must be registered with `app.databases.use(...)` _before_ configuring the Queues driver.

Example:

```swift
extension DatabaseID {
    static var queues: Self { .init(string: "my_queues_db") }
}

func configure(_ app: Application) async throws {
    app.databases.use(.postgres(configuration: ...), as: .queues)
    app.queues.use(.fluent(.queues))
}
```

### Preserving records of completed jobs

By default, once a job has finished, it is removed entirely from the jobs table in the database. Setting the `preserveCompletedJobs` parameter to `true` configures the driver to leave finished jobs in the jobs table, with a state of `completed`.

Example:

```swift
func configure(_ app: Application) async throws {
    app.queues.use(.fluent(preserveCompletedJobs: true))
}
```

> [!NOTE]
> The driver never removes jobs in the `completed` state from the table, even if `preserveCompletedJobs` is later turned off. "Cleaning up" completed jobs must be done manually, with a query such as `DELETE FROM _jobs_meta WHERE state='completed'`.

### Changing the name and location of the jobs table

By default, the jobs table is created in the default space (e.g. the current schema - usually `public` - in PostgreSQL, or the current database in MySQL and SQLite) and has the name `_jobs_meta`. The table name and space may be configured, using the `jobsTableName` and `jobsTableSpace` parameters respectively. If `JobModelMigration` or `JobModelOldFormatMigration` are in use (as is recommended), the same name and space must be passed to both its initializer and the driver for the migration to work correctly.

Example:

```swift
func configure(_ app: Application) async throws {
    app.migrations.add(JobModelMigration(jobsTableName: "_my_jobs", jobsTableSpace: "not_public"))
    // OR
    app.migrations.add(JobModelOldFormatMigration(jobsTableName: "_my_jobs", jobsTableSpace: "not_public"))
    
    app.queues.use(.fluent(jobsTableName: "_my_jobs", jobsTableSpace: "not_public"))
}
```

> [!NOTE]
> When `JobModelMigration` or `JobModelOldFormatMigration` are used with PostgreSQL, the table name is used as a prefix for the enumeration type created to represent job states in the database, and the enumeration type is created in the same space as the table.

## Caveats

### Polling interval and number of workers

By default, the Vapor Queues system starts 2 workers per available CPU core, with each worker would polling the database once per second. On a 4-core system, this would results in 8 workers querying the database every second. Most configurations do not need this many workers. Additionally, when using SQLite as the underlying database it is generally inadvisable to run more than one worker at a time, as SQLite does not have the necessary support for locking to make this safe.

The polling interval can be changed using the `refreshInterval` configuration setting:

```swift
app.queues.configuration.refreshInterval = .seconds(5)
```

Likewise, the number of workers to start can be changed via the `workerCount` setting:

```swift
app.queues.configuration.workerCount = 1
```
