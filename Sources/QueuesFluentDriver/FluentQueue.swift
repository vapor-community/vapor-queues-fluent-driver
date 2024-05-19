@preconcurrency import Queues
import SQLKit
import NIOConcurrencyHelpers
import struct Foundation.Data

/// An implementation of `Queue` which stores job data and metadata in a Fluent database.
public struct FluentQueue: Queue, Sendable {
    // See `Queue.context`.
    public let context: QueueContext

    let sqlDb: any SQLDatabase
    
    let _sqlLockingClause: NIOLockedValueBox<(any SQLExpression)?> = .init(nil) // needs a lock for the queue to be `Sendable`

    // See `Queue.get(_:)`.
    public func get(_ id: JobIdentifier) -> EventLoopFuture<JobData> {
        self.sqlDb.select()
            .columns("payload", "max_retry_count", "queue_name", "state", "job_name", "delay_until", "queued_at", "attempts", "updated_at")
            .from(JobModel.schema)
            .where("id", .equal, id.string)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMapThrowing {
                try $0.decode(model: JobModel.self, keyDecodingStrategy: .convertFromSnakeCase)
            }.map {
                .init(payload: .init($0.payload), maxRetryCount: $0.maxRetryCount, jobName: $0.jobName, delayUntil: $0.delayUntil, queuedAt: $0.queuedAt)
            }
    }
    
    // See `Queue.set(_:to:)`.
    public func set(_ id: JobIdentifier, to jobStorage: JobData) -> EventLoopFuture<Void> {
        self.sqlDb.eventLoop.makeFutureWithTask {
            try await self.sqlDb.insert(into: JobModel.schema)
                .columns("id", "queue_name", "job_name", "queued_at", "delay_until", "state", "max_retry_count", "attempts", "payload", "updated_at")
                .values(
                    SQLBind(id.string),
                    SQLBind(self.queueName.string),
                    SQLBind(jobStorage.jobName),
                    SQLBind(jobStorage.queuedAt),
                    SQLBind(jobStorage.delayUntil),
                    SQLLiteral.string(StoredJobState.pending.rawValue),
                    SQLBind(jobStorage.maxRetryCount),
                    SQLBind(jobStorage.attempts),
                    SQLBind(Data(jobStorage.payload)),
                    .now()
                )
                // .model(JobModel(id: id, queue: self.queueName, jobData: jobStorage), keyEncodingStrategy: .convertToSnakeCase) // because enums!
                .run()
        }
    }
    
    // See `Queue.clear(_:)`.
    public func clear(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.get(id).flatMap { _ in
            self.sqlDb.delete(from: JobModel.schema)
                .where("id", .equal, id.string)
                .where("state", .notEqual, SQLLiteral.string(StoredJobState.completed.rawValue))
                .run()
        }
    }
    
    // See `Queue.push(_:)`.
    public func push(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.sqlDb
            .update(JobModel.schema)
            .set("state", to: SQLLiteral.string(StoredJobState.pending.rawValue))
            .set("updated_at", to: .now())
            .where("id", .equal, id.string)
            .run()
    }
    
    // See `Queue.pop()`.
    public func pop() -> EventLoopFuture<JobIdentifier?> {
        self.sqlDb.eventLoop.makeFutureWithTask {
            // Special case: For MySQL < 8.0, we can't use `SKIP LOCKED`. This is a really hackneyed solution,
            // but we need to execute a database query to get the version information, `makeQueue(with:)`
            // is purely synchronous, and `SQLDatabase.version` is not implemented in MySQLKit at the time
            // of this writing.
            if self._sqlLockingClause.withLockedValue({ $0 }) == nil {
                switch self.sqlDb.dialect.name {
                case "mysql":
                    let version = try await self.sqlDb.select()
                        .column(SQLFunction("version"), as: "version")
                        .first(decodingColumn: "version", as: String.self) ?? "" // always returns one row
                    // This is a really lazy check and it knows it; we know MySQLNIO doesn't support versions older than 5.x.
                    if version.starts(with: "5.") || !(version.first?.isNumber ?? false) {
                        self._sqlLockingClause.withLockedValue { $0 = SQLLockingClause.update }
                    } else {
                        fallthrough
                    }
                default:
                    self._sqlLockingClause.withLockedValue { $0 = SQLLockingClauseWithSkipLocked.updateSkippingLocked }
                }
            }

            let select = self.sqlDb
                .select()
                .column("id")
                .from(JobModel.schema)
                .where("state", .equal, SQLLiteral.string(StoredJobState.pending.rawValue))
                .where("queue_name", .equal, self.queueName.string)
                .where(.dateValue(.function("coalesce", SQLColumn("delay_until"), SQLNow())), .lessThanOrEqual, .now())
                .orderBy("delay_until")
                .limit(1)
                .lockingClause(self._sqlLockingClause.withLockedValue { $0! }) // we've always set it by the time we get here
            
            if self.sqlDb.dialect.supportsReturning {
                return try await self.sqlDb.update(JobModel.schema)
                    .set("state", to: SQLLiteral.string(StoredJobState.processing.rawValue))
                    .set("updated_at", to: .now())
                    .where("id", .equal, .group(select.query))
                    .returning("id")
                    .first(decodingColumn: "id", as: String.self)
                    .map(JobIdentifier.init(string:))
            } else {
                return try await self.sqlDb.transaction { transaction in
                    guard let id = try await transaction.raw("\(select.query)") // using raw() to make sure we run on the transaction connection
                        .first(decodingColumn: "id", as: String.self)
                    else {
                        return nil
                    }

                    try await transaction
                        .update(JobModel.schema)
                        .set("state", to: SQLLiteral.string(StoredJobState.processing.rawValue))
                        .set("updated_at", to: .now())
                        .where("id", .equal, id)
                        .where("state", .equal, SQLLiteral.string(StoredJobState.pending.rawValue))
                        .run()
                    
                    return JobIdentifier(string: id)
                }
            }
        }
    }
}
