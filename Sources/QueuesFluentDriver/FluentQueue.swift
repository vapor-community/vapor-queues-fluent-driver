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
    
    // See `Queue.set(_:to:)`.
    public func set(_ id: JobIdentifier, to jobStorage: JobData) -> EventLoopFuture<Void> {
        self.sqlDb.eventLoop.makeFutureWithTask {

            try await self.sqlDb.insert(into: JobModel.self)
//                .model(JobModel(id: id, queue: self.queueName, jobData: jobStorage), keyEncodingStrategy: .convertToSnakeCase)
                .columns(\JobModel.$id, \JobModel.$queue, \JobModel.$jobName, \JobModel.$queuedAt, \JobModel.$delayUntil,
                         \JobModel.$state, \JobModel.$maxRetryCount, \JobModel.$attempts, \JobModel.$payload, \JobModel.$updatedAt)
                .values(.bind(id.string), .bind(self.queueName.string), .bind(jobStorage.jobName), .bind(jobStorage.queuedAt), .bind(jobStorage.delayUntil),
                        .bind(StoredJobState.pending), .bind(jobStorage.maxRetryCount), .bind(jobStorage.attempts ?? 0), .bind(jobStorage.payload), .now())
                .onConflict { $0
//                    .set(excludedContentOf: JobModel(id: id, queue: self.queueName, jobData: jobStorage), keyEncodingStrategy: .convertToSnakeCase)
                    .set(excludedValueOf: \JobModel.$id)           .set(excludedValueOf: \JobModel.$queue)
                    .set(excludedValueOf: \JobModel.$jobName)      .set(excludedValueOf: \JobModel.$queuedAt)
                    .set(excludedValueOf: \JobModel.$delayUntil)   .set(excludedValueOf: \JobModel.$state)
                    .set(excludedValueOf: \JobModel.$maxRetryCount).set(excludedValueOf: \JobModel.$attempts)
                    .set(excludedValueOf: \JobModel.$payload)      .set(excludedValueOf: \JobModel.$updatedAt)
                }
                .run()
        }
    }
    
    // See `Queue.clear(_:)`.
    public func clear(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.get(id).flatMap { _ in
            self.sqlDb.delete(from: JobModel.self)
                .where(\JobModel.$id, .equal, id.string)
                .where(\JobModel.$state, .notEqual, StoredJobState.completed)
                .run()
        }
    }
    
    // See `Queue.push(_:)`.
    public func push(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.sqlDb
            .update(JobModel.sqlTable)
            .set(\JobModel.$state, to: StoredJobState.pending)
            .set(\JobModel.$updatedAt, to: .now())
            .where(\JobModel.$id, .equal, id.string)
            .run()
    }
    
    // See `Queue.pop()`.
    public func pop() -> EventLoopFuture<JobIdentifier?> {
        self.sqlDb.eventLoop.makeFutureWithTask {
            let select = self.sqlDb
                .select()
                .column(\JobModel.$id)
                .from(JobModel.self)
                .where(\JobModel.$state, .equal, StoredJobState.pending)
                .where(\JobModel.$queue, .equal, self.queueName.string)
                .where(.dateValue(.function("coalesce", JobModel.sqlColumn(\.$delayUntil), SQLNow())), .lessThanOrEqual, .now())
                .orderBy(\JobModel.$delayUntil)
                .limit(1)
                .lockingClause(SQLLockingClauseWithSkipLocked.updateSkippingLocked)
            
            if self.sqlDb.dialect.supportsReturning {
                return try await self.sqlDb.update(JobModel.sqlTable)
                    .set(\JobModel.$state, to: StoredJobState.processing)
                    .set(\JobModel.$updatedAt, to: .now())
                    .where(\JobModel.$id, .equal, .group(select.query))
                    .returning(JobModel.sqlColumn(\.$id))
                    .first(decodingColumn: JobModel.key(for: \.$id), as: String.self)
                    .map(JobIdentifier.init(string:))
            } else {
                return try await self.sqlDb.transaction { transaction in
                    guard let id = try await transaction.raw("\(select.query)") // using raw() to make sure we run on the transaction connection
                        .first(decodingColumn: JobModel.key(for: \.$id), as: String.self)
                    else {
                        return nil
                    }

                    try await transaction
                        .update(JobModel.sqlTable)
                        .set(\JobModel.$state, to: StoredJobState.processing)
                        .set(\JobModel.$updatedAt, to: .now())
                        .where(\JobModel.$id, .equal, id)
                        .where(\JobModel.$state, .equal, StoredJobState.pending)
                        .run()
                    
                    return JobIdentifier(string: id)
                }
            }
        }
    }
}
