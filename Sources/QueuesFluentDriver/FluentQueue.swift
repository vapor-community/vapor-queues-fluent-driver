@preconcurrency import Queues
@preconcurrency import SQLKit
@preconcurrency import FluentKit

/// [SE-0418] negates the need for this ugliness, but until then, to silence the Sendability warnings for the keypaths,
/// we mark keypaths with the relevant root type unchecked. As this is a retroactive conformance for a type not owned
/// by this module, per [SE-0364] we need to explicitly mark it so when the attribute is available.
///
/// [SE-0418]: https://github.com/apple/swift-evolution/blob/main/proposals/0418-inferring-sendable-for-methods.md
/// [SE-0364]: https://github.com/apple/swift-evolution/blob/main/proposals/0364-retroactive-conformance-warning.md
#if compiler(<5.10) || !$InferSendableFromCaptures
#if compiler(>=5.10) && $RetroactiveAttribute
extension KeyPath: @retroactive @unchecked Sendable where Root == JobDataModel {}
#else
extension KeyPath: @unchecked Sendable where Root == JobDataModel {}
#endif
#endif

/// An implementation of `Queue` which stores job data and metadata in a Fluent database.
public struct FluentQueue: Queue, Sendable {
    // See `Queue.context`.
    public let context: QueueContext

    let db: any Database
    let sqlDb: any SQLDatabase

    // See `Queue.get(_:)`.
    public func get(_ id: JobIdentifier) -> EventLoopFuture<JobData> {
        self.sqlDb.select()
            .column(JobModel.sqlColumn(\.$data.$payload))
            .column(JobModel.sqlColumn(\.$data.$maxRetryCount))
            .column(JobModel.sqlColumn(\.$data.$jobName))
            .column(JobModel.sqlColumn(\.$data.$delayUntil))
            .column(JobModel.sqlColumn(\.$data.$queuedAt))
            .column(JobModel.sqlColumn(\.$data.$attempts))
            .from(JobModel.sqlTable)
            .where(JobModel.sqlColumn(\.$id), .equal, SQLBind(id.string))
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMapThrowing { row in
                try row.decode(
                    model: JobData.self,
                    prefix: "\(JobModel().$data.key)_",
                    keyDecodingStrategy: .convertFromSnakeCase
                )
            }
    }
    
    // See `Queue.get(_:to:)`.
    public func set(_ id: JobIdentifier, to jobStorage: JobData) -> EventLoopFuture<Void> {
        let jobModel = JobModel(id: id, queue: queueName.string, jobData: JobDataModel(jobData: jobStorage))
        
        return jobModel.save(on: self.db)
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
            .set(JobModel.sqlColumn(\.$state), to: SQLBind(QueuesFluentJobState.pending))
            .where(JobModel.sqlColumn(\.$id), .equal, SQLBind(id.string))
            .run()
    }
    
    // See `Queue.pop()`.
    public func pop() -> EventLoopFuture<JobIdentifier?> {
        self.db.eventLoop.makeFutureWithTask {
            // TODO: Use `SQLSubquery` when it becomes available in upstream SQLKit.
            let select = self.sqlDb
                .select()
                .column(JobModel.sqlColumn(\.$id))
                .from(JobModel.sqlTable)
                .where(JobModel.sqlColumn(\.$state), .equal, SQLBind(QueuesFluentJobState.pending))
                .where(JobModel.sqlColumn(\.$queue), .equal, SQLBind(self.queueName.string))
                .where(SQLFunction("coalesce", args: JobModel.sqlColumn(\.$data.$delayUntil), SQLFunction("now")), .lessThanOrEqual, SQLFunction("now"))
                .orderBy(JobModel.sqlColumn(\.$data.$delayUntil))
                .limit(1)
                .lockingClause(SQLLockingClauseWithSkipLocked.updateSkippingLocked)
            
            if self.sqlDb.dialect.supportsReturning {
                return try await self.sqlDb.update(JobModel.sqlTable)
                    .set(JobModel.sqlColumn(\.$state), to: SQLBind(QueuesFluentJobState.processing))
                    .set(JobModel.sqlColumn(\.$updatedAt), to: SQLFunction("now"))
                    .where(JobModel.sqlColumn(\.$id), .equal, SQLGroupExpression(select.query))
                    .returning(JobModel.sqlColumn(\.$id))
                    .first(decodingColumn: "\(JobModel.key(for: \.$id))", as: String.self)
                    .map(JobIdentifier.init(string:))
            } else {
                return try await self.db.transaction { transaction in
                    let database = transaction as! any SQLDatabase

                    guard let id = try await database.raw("\(select.query)") // using raw() to make sure we run on the transaction connection
                        .first(decodingColumn: "\(JobModel.key(for: \.$id))", as: String.self)
                    else {
                        return nil
                    }

                    try await database
                        .update(JobModel.sqlTable)
                        .set(JobModel.sqlColumn(\.$state), to: SQLBind(QueuesFluentJobState.processing))
                        .set(JobModel.sqlColumn(\.$updatedAt), to: SQLFunction("now"))
                        .where(JobModel.sqlColumn(\.$id), .equal, SQLBind(id))
                        .where(JobModel.sqlColumn(\.$state), .equal, SQLBind(QueuesFluentJobState.pending))
                        .run()
                    
                    return JobIdentifier(string: id)
                }
            }
        }
    }
}
