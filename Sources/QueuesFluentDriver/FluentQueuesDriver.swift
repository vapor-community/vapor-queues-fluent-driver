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
    let databaseId: DatabaseID?

    init(on databaseId: DatabaseID? = nil) {
        self.databaseId = databaseId
    }

    public func makeQueue(with context: QueueContext) -> any Queue {
        /// `QueuesDriver` methods cannot throw, so we report errors by returning a fake queue which
        /// always throws errors when used.
        ///
        /// `Fluent.Databases.database(_:logger:on:)` never returns nil; its optionality is an API mistake.
        /// If a nonexistent `DatabaseID` is requested, it triggers a `fatalError()`.
        let baseDb = context
            .application
            .databases
            .database(self.databaseId, logger: context.logger, on: context.eventLoop)!
        
        guard let sqlDb = baseDb as? any SQLDatabase else {
            return FailingQueue(failure: QueuesFluentError.unsupportedDatabase, context: context)
        }

        return FluentQueue(context: context, sqlDb: sqlDb)
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
