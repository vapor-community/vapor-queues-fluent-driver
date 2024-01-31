import Fluent
import SQLKit
import Queues

public struct FluentQueuesDriver: QueuesDriver {
    let databaseId: DatabaseID?
    let eventLoopGroup: any EventLoopGroup
    
    init(on databaseId: DatabaseID? = nil, on eventLoopGroup: any EventLoopGroup) {
        self.databaseId = databaseId
        self.eventLoopGroup = eventLoopGroup
    }

    public func makeQueue(with context: QueueContext) -> any Queue {
        let baseDb = context
            .application
            .databases
            .database(self.databaseId, logger: context.logger, on: context.eventLoop)
        
        // `QueuesDriver` methods cannot throw, so we report errors by returning a fake queue which
        // always throws errors when used.
        guard let baseDb else {
            return FailingQueue(failure: QueuesFluentError.databaseNotFound, context: context)
        }
        
        guard let sqlDb = baseDb as? any SQLDatabase else {
            return FailingQueue(failure: QueuesFluentError.unsupportedDatabase, context: context)
        }

        return FluentQueue(
            context: context,
            db: baseDb,
            sqlDb: sqlDb
        )
    }
    
    public func shutdown() {}
}

struct FailingQueue: Queue {
    let failure: any Error
    let context: QueueContext

    func get(_: JobIdentifier) -> EventLoopFuture<JobData> { self.eventLoop.future(error: self.failure) }
    func set(_: JobIdentifier, to: JobData) -> EventLoopFuture<Void> { self.eventLoop.future(error: self.failure) }
    func clear(_: JobIdentifier) -> EventLoopFuture<Void> { self.eventLoop.future(error: self.failure) }
    func push(_: JobIdentifier) -> EventLoopFuture<Void> { self.eventLoop.future(error: self.failure) }
    func pop() -> EventLoopFuture<JobIdentifier?> { self.eventLoop.future(error: self.failure) }
}
