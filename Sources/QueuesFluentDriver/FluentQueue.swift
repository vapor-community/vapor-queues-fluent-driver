import Foundation
@preconcurrency import Queues
@preconcurrency import FluentKit
@preconcurrency import SQLKit

public struct FluentQueue: Queue, Sendable {
    public let context: QueueContext

    let db: any Database
    let sqlDb: any SQLDatabase
    let useSoftDeletes: Bool

    public func get(_ id: JobIdentifier) -> EventLoopFuture<JobData> {
        self.db.query(JobModel.self)
            .filter(\.$id == id.string)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMapThrowing { job in
                JobData(
                    payload: Array(job.data.payload),
                    maxRetryCount: job.data.maxRetryCount,
                    jobName: job.data.jobName,
                    delayUntil: job.data.delayUntil,
                    queuedAt: job.data.queuedAt,
                    attempts: job.data.attempts ?? 0
                )
            }
    }
    
    public func set(_ id: JobIdentifier, to jobStorage: JobData) -> EventLoopFuture<Void> {
        let jobModel = JobModel(id: id, queue: queueName.string, jobData: JobDataModel(jobData: jobStorage))
        
        // If the job must run at a later time, ensure it won't be picked earlier since
        // we sort pending jobs by date when querying
        jobModel.runAtOrAfter = jobStorage.delayUntil ?? Date()
        
        return jobModel.save(on: self.db)
    }
    
    public func clear(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        // This does the equivalent of a Fluent soft delete, but sets the `state` to `completed`
        self.db.query(JobModel.self)
            .filter(\.$id == id.string)
            .filter(\.$state != .completed)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMap { job in
                if self.useSoftDeletes {
                    job.state = .completed
                    job.deletedAt = Date()
                    return job.update(on: self.db)
                } else {
                    return job.delete(force: true, on: self.db)
                }
        }
    }
    
    public func push(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        self.sqlDb
            .update(JobModel.sqlTable)
            .set(JobModel.sqlColumn(\.$state), to: SQLBind(QueuesFluentJobState.pending))
            .where(JobModel.sqlColumn(\.$id), .equal, SQLBind(id.string))
            .run()
    }
    
    /// Currently selects the oldest job pending execution
    public func pop() -> EventLoopFuture<JobIdentifier?> {
        self.db.eventLoop.makeFutureWithTask {
            // TODO: Use `SQLSubquery` instead when it becomes available in upstream SQLKit.
            let select = self.sqlDb
                .select()
                .column(JobModel.sqlColumn(\.$id))
                .from(JobModel.sqlTable)
                .where(JobModel.sqlColumn(\.$state), .equal, SQLBind(QueuesFluentJobState.pending))
                .where(JobModel.sqlColumn(\.$queue), .equal, SQLBind(self.queueName.string))
                .where(JobModel.sqlColumn(\.$runAtOrAfter), .lessThanOrEqual, SQLFunction("now"))
                .orderBy(JobModel.sqlColumn(\.$runAtOrAfter))
                .limit(1)
                .lockingClause(SQLSkipLocked.forUpdateSkipLocked)
            
            switch self.sqlDb.dialect.name {
                case "postgresql",
                     "sqlite":     return try await ReturningClausePopQuery.pop(db: self.db, select: select).map(JobIdentifier.init(string:))
                case "mysql":      return try await TransactionalPopQuery.pop(db: self.db, select: select).map(JobIdentifier.init(string:))
                default:           preconditionFailure("This should have already been checked.")
            }
        }
    }
}
