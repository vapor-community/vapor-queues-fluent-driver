import FluentKit
import SQLKit

public struct JobMetadataMigrate: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(JobModel.schema)
            .field(JobModel.key(for: \.$id),           .string, .identifier(auto: false))
            .field(JobModel.key(for: \.$queue),        .string, .required)
            .field(JobModel.key(for: \.$state),        .string, .required)
            .field(JobModel.key(for: \.$runAtOrAfter), .datetime)
            .field(JobModel.key(for: \.$updatedAt),    .datetime)
            .field(JobModel.key(for: \.$deletedAt),    .datetime)
            // "group"/nested model JobDataModel
            .field(.prefix("data", JobDataModel.key(for: \.$payload)),       .array(of: .uint8), .required)
            .field(.prefix("data", JobDataModel.key(for: \.$maxRetryCount)), .int, .required)
            .field(.prefix("data", JobDataModel.key(for: \.$attempts)),      .int)
            .field(.prefix("data", JobDataModel.key(for: \.$delayUntil)),    .datetime)
            .field(.prefix("data", JobDataModel.key(for: \.$queuedAt)),      .datetime, .required)
            .field(.prefix("data", JobDataModel.key(for: \.$jobName)),       .string, .required)
            .create()

        // Mysql could lock the entire table if there's no index on the fields of the WHERE clause used in `FluentQueue.pop()`.
        // Order of the fields in the composite index and order of the fields in the WHERE clauses should match.
        // Or I got totally confused reading their doc, which is also a possibility.
        // Postgres seems to not be so sensitive and should be happy with the following indices.
        try await (database as! any SQLDatabase)
            .create(index: "i_\(JobModel.schema)_\(JobModel.key(for: \.$state))_\(JobModel.key(for: \.$queue))")
            .on(JobModel.sqlTable)
            .column(JobModel.sqlColumn(\.$state))
            .column(JobModel.sqlColumn(\.$queue))
            .column(JobModel.sqlColumn(\.$runAtOrAfter))
            .run()
    }
    
    public func revert(on database: any Database) async throws {
        try await database.schema(JobModel.schema).delete()
    }
}
