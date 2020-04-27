import Foundation
import Queues
import Fluent
import SQLKit

struct FluentQueue {
    let db: Database?
    let context: QueueContext
    let dbType: QueuesFluentDbType?
    let useSoftDeletes: Bool
}

extension FluentQueue: Queue {
    func get(_ id: JobIdentifier) -> EventLoopFuture<JobData> {
        guard let db = db else {
            return self.context.eventLoop.makeFailedFuture(QueuesFluentError.databaseNotFound)
        }
        return db.query(JobModel.self)
            .filter(\.$jobId == id.string)
            .filter(\.$state != .pending)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMapThrowing { job in
                return try JSONDecoder().decode(JobData.self, from: job.data)
            }
    }
    
    func set(_ id: JobIdentifier, to jobStorage: JobData) -> EventLoopFuture<Void> {
        guard let db = db else {
            return self.context.eventLoop.makeFailedFuture(QueuesFluentError.databaseNotFound)
        }
        //let data = try! JSONEncoder().encode(jobStorage)
        do {
            let jobModel = try JobModel(jobId: id.string, queue: queueName.string, data: jobStorage)
            return jobModel.save(on: db)
        }
        catch {
            return db.eventLoop.makeFailedFuture(QueuesFluentError.jobDataEncodingError(error.localizedDescription))
        }
        
    }
    
    func clear(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        guard let db = db else {
            return self.context.eventLoop.makeFailedFuture(QueuesFluentError.databaseNotFound)
        }
        // This does the equivalent of a Fluent Softdelete but sets the `state` to `completed`
        return db.query(JobModel.self)
            .filter(\.$jobId == id.string)
            .filter(\.$state != .completed)
            .first()
            .unwrap(or: QueuesFluentError.missingJob(id))
            .flatMap { job in
                if self.useSoftDeletes {
                    job.state = .completed
                    job.deletedAt = Date()
                    return job.update(on: db)
                } else {
                    return job.delete(force: true, on: db)
                }
        }
    }
    
    func push(_ id: JobIdentifier) -> EventLoopFuture<Void> {
        guard let db = db, let sqlDb = db as? SQLDatabase else {
            return self.context.eventLoop.makeFailedFuture(QueuesFluentError.databaseNotFound)
        }
        return sqlDb
            .update(JobModel.schema)
            .set(SQLColumn("\(FieldKey.state)"), to: SQLBind(QueuesFluentJobState.pending))
            .where(SQLColumn("\(FieldKey.jobId)"), .equal, SQLBind(id.string))
            .run()
    }
    
    /// Currently selects the oldest job pending execution
    func pop() -> EventLoopFuture<JobIdentifier?> {
        guard let db = db, let sqlDb = db as? SQLDatabase else {
            return self.context.eventLoop.makeFailedFuture(QueuesFluentError.databaseNotFound)
        }
        
        var selectQuery = sqlDb
            .select()
            .column("\(FieldKey.jobId)")
            .from(JobModel.schema)
            .where(SQLColumn("\(FieldKey.state)"), .equal, SQLBind(QueuesFluentJobState.pending))
            .where(SQLColumn("\(FieldKey.queue)"), .equal, SQLBind(self.queueName.string))
            .orderBy("\(FieldKey.createdAt)")
            .limit(1)
        if self.dbType != .sqlite {
            selectQuery = selectQuery.lockingClause(SQLSkipLocked.forUpdateSkipLocked)
        }
        
        var popProvider: PopQueryProtocol!
        switch (self.dbType) {
            case .postgresql:
                popProvider = PostgresPop()
            case .mysql:
                popProvider = MySQLPop()
            case .sqlite:
                popProvider = SqlitePop()
            case .none:
                return db.context.eventLoop.makeFailedFuture(QueuesFluentError.databaseNotFound)
        }
        return popProvider.pop(db: db, select: selectQuery.query).optionalMap { id in
            return JobIdentifier(string: id)
        }
    }
    
    /// /!\ This is a non standard extension.
    public func list(queue: String? = nil, state: QueuesFluentJobState = .pending) -> EventLoopFuture<[JobData]> {
        guard let db = db, let sqlDb = db as? SQLDatabase else {
            return self.context.eventLoop.makeFailedFuture(QueuesFluentError.databaseNotFound)
        }
        var query = sqlDb
            .select()
            .from(JobModel.schema)
            .where(SQLColumn("\(FieldKey.state)"), .equal, SQLBind(state))
        if let queue = queue {
            query = query.where(SQLColumn("\(FieldKey.queue)"), .equal, SQLBind(queue))
        }
        if self.dbType != .sqlite {
            query = query.lockingClause(SQLSkipLocked.forShareSkipLocked)
        }
        var pendingJobs = [JobData]()
        return sqlDb.execute(sql: query.query) { (row) -> Void in
            do {
                let jobData = try row.decode(column: "\(FieldKey.data)", as: JobData.self)
                pendingJobs.append(jobData)
            }
            catch {
                db.eventLoop.makeFailedFuture(QueuesFluentError.jobDataDecodingError("\(error)")).whenSuccess {$0}
            }
        }
        .map {
            return pendingJobs
        }
    }
}
