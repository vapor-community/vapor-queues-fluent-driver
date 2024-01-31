import Vapor
import FluentKit
import Queues

extension Application.Queues.Provider {
    /// - Parameters:
    ///   - databaseId: A Fluent `DatabaseID` configured for a compatible database.
    public static func fluent(_ databaseId: DatabaseID? = nil) -> Self {
        .init {
            $0.queues.use(custom:
                FluentQueuesDriver(on: databaseId, on: $0.eventLoopGroup)
            )
        }
    }
}
