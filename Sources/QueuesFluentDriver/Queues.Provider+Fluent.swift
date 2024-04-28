import class Vapor.Application
import struct FluentKit.DatabaseID
import Queues

extension Application.Queues.Provider {
    /// Retrieve a queues provider which specifies use of the Fluent driver with a given database.
    ///
    /// Example usage:
    ///
    /// ```swift
    /// func configure(_ app: Application) async throws {
    ///     // ...
    ///     app.databases.use(.sqlite(.memory), as: .sqlite)
    ///     app.queues.use(.fluent(.sqlite))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - databaseId: A Fluent `DatabaseID` configured for a compatible database, or `nil` to use the
    ///     default database.
    /// - Returns: An appropriately configured provider for `Application.Queues.use(_:)`.
    public static func fluent(_ databaseId: DatabaseID? = nil) -> Self {
        .init { $0.queues.use(custom: FluentQueuesDriver(on: databaseId)) }
    }
}
