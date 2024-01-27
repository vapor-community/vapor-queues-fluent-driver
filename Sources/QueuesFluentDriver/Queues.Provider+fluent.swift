import Vapor
import FluentKit
import Queues

extension Application.Queues.Provider {
    /// - Parameters:
    ///   - databaseId: A Fluent `DatabaseID` configured for a compatible database.
    ///   - useSoftDeletes: If `true`, completed jobs are flagged via soft-deletion.
    public static func fluent(_ databaseId: DatabaseID? = nil, useSoftDeletes: Bool = false) -> Self {
        .init {
            $0.queues.use(custom:
                FluentQueuesDriver(on: databaseId, useSoftDeletes: useSoftDeletes, on: $0.eventLoopGroup)
            )
        }
    }
}
