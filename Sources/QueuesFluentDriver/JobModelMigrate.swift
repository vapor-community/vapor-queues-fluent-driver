import protocol FluentKit.AsyncMigration
import protocol FluentKit.Database
import protocol SQLKit.SQLDatabase

public struct JobMetadataMigrate: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(JobModel.schema, space: JobModel.space)
            .field(JobModel.key(for: \.$id),           .string, .identifier(auto: false))
            .field(JobModel.key(for: \.$queue),        .string, .required)
            .field(JobModel.key(for: \.$state),        .string, .required)
            .field(JobModel.key(for: \.$updatedAt),    .datetime)
            .field(JobModel.key(for: \.$deletedAt),    .datetime)
            // "group"/nested model JobDataModel
            .field(JobModel.key(for: \.$data.$payload),       .array(of: .uint8), .required)
            .field(JobModel.key(for: \.$data.$maxRetryCount), .int, .required)
            .field(JobModel.key(for: \.$data.$attempts),      .int)
            .field(JobModel.key(for: \.$data.$delayUntil),    .datetime)
            .field(JobModel.key(for: \.$data.$queuedAt),      .datetime, .required)
            .field(JobModel.key(for: \.$data.$jobName),       .string, .required)
            .create()

        try await (database as! any SQLDatabase)
            .create(index: "i_\(JobModel.schema)_\(JobModel.key(for: \.$state))_\(JobModel.key(for: \.$queue))")
            .on(JobModel.sqlTable)
            .column(JobModel.sqlColumn(\.$state))
            .column(JobModel.sqlColumn(\.$queue))
            .column(JobModel.sqlColumn(\.$data.$delayUntil))
            .run()
    }
    
    public func revert(on database: any Database) async throws {
        try await database.schema(JobModel.schema, space: JobModel.space).delete()
    }
}
