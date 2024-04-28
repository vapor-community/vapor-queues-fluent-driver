@preconcurrency import Queues
@preconcurrency import SQLKit

/// An implementation of `Queue` which stores job data and metadata in a Fluent database.
public struct FluentQueue: Queue, Sendable {
    // See `Queue.context`.
    public let context: QueueContext

    let sqlDb: any SQLDatabase

    // See `Queue.get(_:)`.
    public func get(_ id: JobIdentifier) -> EventLoopFuture<JobData> {
        self.sqlDb.select()
            .columns("payload", "max_retry_count", "job_name", "delay_until", "queued_at", "attempts")
            .from(JobModel.schema)
            .where("id", .equal, id.string)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMapThrowing {
                try $0.decode(model: JobData.self, keyDecodingStrategy: .convertFromSnakeCase)
            }
    }
    
    // See `Queue.set(_:to:)`.
    public func set(_ id: JobIdentifier, to jobStorage: JobData) -> EventLoopFuture<Void> {
        self.sqlDb.eventLoop.makeFutureWithTask {
            try await self.sqlDb.insert(into: JobModel.schema)
                .model(JobModel(id: id, queue: self.queueName, jobData: jobStorage), keyEncodingStrategy: .convertToSnakeCase)
                .onConflict { try $0
                    .set(excludedContentOf: JobModel(id: id, queue: self.queueName, jobData: jobStorage), keyEncodingStrategy: .convertToSnakeCase)
                }
                .run()
        }
    }
    
    // See `Queue.clear(_:)`.
    public func clear(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.get(id).flatMap { _ in
            self.sqlDb.delete(from: JobModel.schema)
                .where("id", .equal, id.string)
                .where("state", .notEqual, StoredJobState.completed)
                .run()
        }
    }
    
    // See `Queue.push(_:)`.
    public func push(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.sqlDb
            .update(JobModel.schema)
            .set("state", to: StoredJobState.pending)
            .set("updated_at", to: .now())
            .where("id", .equal, id.string)
            .run()
    }
    
    // See `Queue.pop()`.
    public func pop() -> EventLoopFuture<JobIdentifier?> {
        self.sqlDb.eventLoop.makeFutureWithTask {
            let select = self.sqlDb
                .select()
                .column("id")
                .from(JobModel.schema)
                .where("state", .equal, StoredJobState.pending)
                .where("queue_name", .equal, self.queueName.string)
                .where(.dateValue(.function("coalesce", SQLColumn("delay_until"), SQLNow())), .lessThanOrEqual, .now())
                .orderBy("delay_until")
                .limit(1)
                .lockingClause(SQLLockingClauseWithSkipLocked.updateSkippingLocked)
            
            if self.sqlDb.dialect.supportsReturning {
                return try await self.sqlDb.update(JobModel.schema)
                    .set("state", to: StoredJobState.processing)
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
                        .set("state", to: StoredJobState.processing)
                        .set("updated_at", to: .now())
                        .where("id", .equal, id)
                        .where("state", .equal, StoredJobState.pending)
                        .run()
                    
                    return JobIdentifier(string: id)
                }
            }
        }
    }
}
