# ``QueuesFluentDriver``

@Metadata {
    @TitleHeading("Package")
}

A driver for [Queues]. Uses [Fluent] to store job metadata in an SQL database.

[Queues]: https://github.com/vapor/queues
[Fluent]: https://github.com/vapor/fluent

## Overview

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
