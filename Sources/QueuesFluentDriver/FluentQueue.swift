@preconcurrency import Queues
@preconcurrency import SQLKit
@preconcurrency import FluentKit

/// An implementation of `Queue` which stores job data and metadata in a Fluent database.
public struct FluentQueue: Queue, Sendable {
    // See `Queue.context`.
    public let context: QueueContext

    let db: any Database
    let sqlDb: any SQLDatabase

    // See `Queue.get(_:)`.
    public func get(_ id: JobIdentifier) -> EventLoopFuture<JobData> {
        self.sqlDb.select()
            .columns(\JobModel.$payload, \JobModel.$maxRetryCount, \JobModel.$jobName,
                     \JobModel.$delayUntil, \JobModel.$queuedAt, \JobModel.$attempts)
            .from(JobModel.self)
            .where(\JobModel.$id, .equal, id.string)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMapThrowing {
                try $0.decode(model: JobData.self, keyDecodingStrategy: .convertFromSnakeCase)
            }
    }
    
    // See `Queue.get(_:to:)`.
    public func set(_ id: JobIdentifier, to jobStorage: JobData) -> EventLoopFuture<Void> {
        JobModel(id: id, queue: queueName.string, jobData: jobStorage).save(on: self.db)
    }
    
    // See `Queue.clear(_:)`.
    public func clear(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.db.query(JobModel.self)
            .filter(\.$id == id.string)
            .filter(\.$state != .completed)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMap { $0.delete(force: true, on: self.db) }
    }
    
    // See `Queue.push(_:)`.
    public func push(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.sqlDb
            .update(JobModel.sqlTable)
            .set(\JobModel.$state, to: QueuesFluentJobState.pending)
            .where(\JobModel.$id, .equal, id.string)
            .run()
    }
    
    // See `Queue.pop()`.
    public func pop() -> EventLoopFuture<JobIdentifier?> {
        self.db.eventLoop.makeFutureWithTask {
            // TODO: Use `SQLSubquery` when it becomes available in upstream SQLKit.
            let select = self.sqlDb
                .select()
                .column(\JobModel.$id)
                .from(JobModel.self)
                .where(\JobModel.$state, .equal, QueuesFluentJobState.pending)
                .where(\JobModel.$queue, .equal, self.queueName.string)
                .where(.dateValue(.function("coalesce", JobModel.sqlColumn(\.$delayUntil), SQLNow())), .lessThanOrEqual, .now())
                .orderBy(\JobModel.$delayUntil)
                .limit(1)
                .lockingClause(SQLLockingClauseWithSkipLocked.updateSkippingLocked)
            
            if self.sqlDb.dialect.supportsReturning {
                return try await self.sqlDb.update(JobModel.sqlTable)
                    .set(\JobModel.$state, to: QueuesFluentJobState.processing)
                    .set(\JobModel.$updatedAt, to: .now())
                    .where(\JobModel.$id, .equal, .group(select.query))
                    .returning(JobModel.sqlColumn(\.$id))
                    .first(decodingColumn: JobModel.key(for: \.$id), as: String.self)
                    .map(JobIdentifier.init(string:))
            } else {
                return try await self.db.transaction { transaction in
                    let database = transaction as! any SQLDatabase

                    guard let id = try await database.raw("\(select.query)") // using raw() to make sure we run on the transaction connection
                        .first(decodingColumn: JobModel.key(for: \.$id), as: String.self)
                    else {
                        return nil
                    }

                    try await database
                        .update(JobModel.sqlTable)
                        .set(\JobModel.$state, to: QueuesFluentJobState.processing)
                        .set(\JobModel.$updatedAt, to: .now())
                        .where(\JobModel.$id, .equal, id)
                        .where(\JobModel.$state, .equal, QueuesFluentJobState.pending)
                        .run()
                    
                    return JobIdentifier(string: id)
                }
            }
        }
    }
}
