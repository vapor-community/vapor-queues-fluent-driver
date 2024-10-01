import class NIOCore.EventLoopFuture
import struct Fluent.DatabaseID
import protocol SQLKit.SQLDatabase
import protocol Queues.QueuesDriver
import protocol Queues.Queue
import protocol Queues.AsyncQueue
import struct Queues.QueueContext
import struct Queues.JobIdentifier
import struct Queues.JobData

public struct FluentQueuesDriver: QueuesDriver {
    let databaseID: DatabaseID?
    let preservesCompletedJobs: Bool
    let jobsTableName: String
    let jobsTableSpace: String?

    init(
        on databaseID: DatabaseID? = nil,
        preserveCompletedJobs: Bool = false,
        jobsTableName: String = "_jobs_meta",
        jobsTableSpace: String? = nil
    ) {
        self.databaseID = databaseID
        self.preservesCompletedJobs = preserveCompletedJobs
        self.jobsTableName = jobsTableName
        self.jobsTableSpace = jobsTableSpace
    }

    public func makeQueue(with context: QueueContext) -> any Queue {
        /// `QueuesDriver` methods cannot throw, so we report errors by returning a fake queue which
        /// always throws errors when used.
        ///
        /// `Fluent.Databases.database(_:logger:on:)` never returns nil; its optionality is an API mistake.
        /// If a nonexistent `DatabaseID` is requested, it triggers a `fatalError()`.
        let baseDB = context
            .application
            .databases
            .database(self.databaseID, logger: context.logger, on: context.eventLoop)!

        guard let sqlDB = baseDB as? any SQLDatabase else {
            return FailingQueue(failure: QueuesFluentError.unsupportedDatabase, context: context)
        }

        return FluentQueue(
            context: context,
            sqlDB: sqlDB,
            preservesCompletedJobs: self.preservesCompletedJobs,
            jobsTable: .init(self.jobsTableName, space: self.jobsTableSpace)
        )
    }
    
    public func shutdown() {}
}

/*private*/ struct FailingQueue: AsyncQueue {
    let failure: any Error
    let context: QueueContext

    func get(_: JobIdentifier) async throws -> JobData   { throw self.failure }
    func set(_: JobIdentifier, to: JobData) async throws { throw self.failure }
    func clear(_: JobIdentifier) async throws            { throw self.failure }
    func push(_: JobIdentifier) async throws             { throw self.failure }
    func pop() async throws -> JobIdentifier?            { throw self.failure }
}
