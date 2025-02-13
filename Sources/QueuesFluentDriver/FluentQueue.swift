import Queues
import SQLKit
import NIOConcurrencyHelpers
import struct Foundation.Data

/// An implementation of `Queue` which stores job data and metadata in a Fluent database.
public struct FluentQueue: AsyncQueue, Sendable {
    // See `Queue.context`.
    public let context: QueueContext

    let sqlDB: any SQLDatabase
    let preservesCompletedJobs: Bool
    let jobsTable: SQLQualifiedTable

    let _sqlLockingClause: NIOLockedValueBox<(any SQLExpression)?> = .init(nil) // needs a lock for the queue to be `Sendable`

    // See `Queue.get(_:)`.
    public func get(_ id: JobIdentifier) async throws -> JobData {
        guard let job = try await self.sqlDB.select()
            .columns("payload", "max_retry_count", "queue_name", "state", "job_name", "delay_until", "queued_at", "attempts", "updated_at")
            .from(self.jobsTable)
            .where("id", .equal, id)
            .first(decoding: JobModel.self, keyDecodingStrategy: .convertFromSnakeCase)
        else {
            throw QueuesFluentError.missingJob(id)
        }

        return .init(payload: .init(job.payload), maxRetryCount: job.maxRetryCount, jobName: job.jobName, delayUntil: job.delayUntil, queuedAt: job.queuedAt)
    }
    
    // See `Queue.set(_:to:)`.
    public func set(_ id: JobIdentifier, to jobStorage: JobData) async throws {
        try await self.sqlDB.insert(into: self.jobsTable)
            .columns("id", "queue_name", "job_name", "queued_at", "delay_until", "state", "max_retry_count", "attempts", "payload", "updated_at")
            .values(
                .bind(id),
                .bind(self.queueName),
                .bind(jobStorage.jobName),
                .bind(jobStorage.queuedAt),
                .bind(jobStorage.delayUntil),
                .literal(StoredJobState.initial),
                .bind(jobStorage.maxRetryCount),
                .bind(jobStorage.attempts),
                .bind(Data(jobStorage.payload)),
                .now()
            )
            // .model(JobModel(id: id, queue: self.queueName, jobData: jobStorage), keyEncodingStrategy: .convertToSnakeCase) // because enums!
            .run()
    }
    
    // See `Queue.clear(_:)`.
    public func clear(_ id: JobIdentifier) async throws {
        if self.preservesCompletedJobs {
            try await self.sqlDB.update(self.jobsTable)
                .set("state", to: .literal(StoredJobState.completed))
                .where("id", .equal, id)
                .run()
        } else {
            try await self.sqlDB.delete(from: self.jobsTable)
                .where("id", .equal, id)
                .run()
        }
    }
    
    // See `Queue.push(_:)`.
    public func push(_ id: JobIdentifier) async throws {
        try await self.sqlDB.update(self.jobsTable)
            .set("state", to: .literal(StoredJobState.pending))
            .set("updated_at", to: .now())
            .where("id", .equal, id)
            .run()
    }
    
    // See `Queue.pop()`.
    public func pop() async throws -> JobIdentifier? {
        // Special case: For MySQL < 8.0, we can't use `SKIP LOCKED`. This is a really hackneyed solution,
        // but we need to execute a database query to get the version information, `makeQueue(with:)`
        // is purely synchronous, and `SQLDatabase.version` is not implemented in MySQLKit at the time
        // of this writing.
        if self._sqlLockingClause.withLockedValue({ $0 }) == nil {
            switch self.sqlDB.dialect.name {
            case "mysql":
                let version = try await self.sqlDB.select()
                    .column(.function("version"), as: "version")
                    .first(decodingColumn: "version", as: String.self)! // always returns one row
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

        let select = SQLSubquery.select { $0
            .column("id")
            .from(self.jobsTable)
            .where("state", .equal, .literal(StoredJobState.pending))
            .where("queue_name", .equal, self.queueName)
            .where(.function("coalesce", .column("delay_until"), .now()), .lessThanOrEqual, .now())
            .orderBy("delay_until")
            .orderBy("queued_at")
            .limit(1)
            .lockingClause(self._sqlLockingClause.withLockedValue { $0! }) // we've always set it by the time we get here
        }

        if self.sqlDB.dialect.supportsReturning {
            return try await self.sqlDB.update(self.jobsTable)
                .set("state", to: .literal(StoredJobState.processing))
                .set("updated_at", to: .now())
                .where("id", .equal, select)
                .returning("id")
                .first(decodingColumn: "id", as: String.self)
                .map(JobIdentifier.init(string:))
        } else {
            return try await self.sqlDB.transaction { transaction in
                guard let id = try await transaction.raw("\(select)") // using raw() to make sure we run on the transaction connection
                    .first(decodingColumn: "id", as: String.self)
                else {
                    return nil
                }

                try await transaction
                    .update(self.jobsTable)
                    .set("state", to: .literal(StoredJobState.processing))
                    .set("updated_at", to: .now())
                    .where("id", .equal, id)
                    .where("state", .equal, .literal(StoredJobState.pending))
                    .run()

                return JobIdentifier(string: id)
            }
        }
    }
}
