import protocol NIOCore.EventLoopGroup
import class NIOCore.EventLoopFuture
import struct Fluent.DatabaseID
import protocol SQLKit.SQLDatabase
import protocol Queues.QueuesDriver
import protocol Queues.Queue
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

private struct FailingQueue: Queue {
    let failure: any Error
    let context: QueueContext

    func get(_: JobIdentifier) -> EventLoopFuture<JobData>           { self.eventLoop.future(error: self.failure) }
    func set(_: JobIdentifier, to: JobData) -> EventLoopFuture<Void> { self.eventLoop.future(error: self.failure) }
    func clear(_: JobIdentifier) -> EventLoopFuture<Void>            { self.eventLoop.future(error: self.failure) }
    func push(_: JobIdentifier) -> EventLoopFuture<Void>             { self.eventLoop.future(error: self.failure) }
    func pop() -> EventLoopFuture<JobIdentifier?>                    { self.eventLoop.future(error: self.failure) }
}
