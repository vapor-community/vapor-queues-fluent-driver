import protocol FluentKit.AsyncMigration
import protocol FluentKit.Database
import protocol SQLKit.SQLDatabase

public struct JobMetadataMigrate: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(JobModel.schema, space: JobModel.space)
            .field("id",              .string,            .identifier(auto: false))
            .field("queue",           .string,            .required)
            .field("state",           .string,            .required)
            .field("updated_at",      .datetime)
            .field("payload",         .array(of: .uint8), .required)
            .field("max_retry_count", .int,               .required)
            .field("attempts",        .int,               .required)
            .field("delay_until",     .datetime)
            .field("queued_at",       .datetime,          .required)
            .field("job_name",        .string,            .required)
            .create()

        try await (database as! any SQLDatabase)
            .create(index: "i_\(JobModel.schema)_state_queue_delayUntil")
            .on(JobModel.sqlTable)
            .column("state")
            .column("queue")
            .column("delay_until")
            .run()
    }
    
    public func revert(on database: any Database) async throws {
        try await database.schema(JobModel.schema, space: JobModel.space).delete()
    }
}
