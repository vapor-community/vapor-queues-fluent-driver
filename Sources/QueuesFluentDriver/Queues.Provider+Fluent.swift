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
    ///   - preservesCompletedJobs: Defaults to `false`. If `true`, completed jobs are marked with a completed
    ///     state rather than being removed from the database.
    ///   - jobsTableName: The name of the database table in which jobs data is stored. Defaults to `_jobs_meta`.
    ///   - jobsTableSpace: The "space" (as defined by Fluent) in which the database table exists. Defaults to `nil`,
    ///     indicating the default space. Most users will not need this parameter.
    /// - Returns: An appropriately configured provider for `Application.Queues.use(_:)`.
    public static func fluent(
        _ databaseID: DatabaseID? = nil,
        preservesCompletedJobs: Bool = false,
        jobsTableName: String = "_jobs_meta",
        jobsTableSpace: String? = nil
    ) -> Self {
        .init {
            $0.queues.use(custom: FluentQueuesDriver(
                on: databaseID,
                preserveCompletedJobs: preservesCompletedJobs,
                jobsTableName: jobsTableName,
                jobsTableSpace: jobsTableSpace
            ))
        }
    }
}
