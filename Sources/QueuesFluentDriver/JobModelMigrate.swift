import protocol FluentKit.AsyncMigration
import protocol FluentKit.Database
import protocol SQLKit.SQLDatabase
import struct SQLKit.SQLRaw

public struct JobModelMigration: AsyncSQLMigration {
    /// Public initializer.
    public init() {}
    
    // See `AsyncSQLMigration.prepare(on:)`.
    public func prepare(on database: any SQLDatabase) async throws {
        let stateEnumType = "\(JobModel.schema)_StoredJobStatus"
        
        try await database.create(enum: stateEnumType)
            .value("pending")
            .value("processing")
            .value("completed")
            .run()
        try await database.create(table: JobModel.sqlTable)
            .column("id",              type: .text,                          .primaryKey(autoIncrement: false))
            .column("queue_name",      type: .text,                          .notNull)
            .column("job_name",        type: .text,                          .notNull)
            .column("queued_at",       type: .custom(SQLRaw("TIMESTAMP")),   .notNull)
            .column("delay_until",     type: .custom(SQLRaw("TIMESTAMP")))
            .column("state",           type: .custom(SQLRaw(stateEnumType)), .notNull)
            .column("max_retry_count", type: .int,                           .notNull)
            .column("attempts",        type: .int,                           .notNull)
            .column("payload",         type: .blob,                          .notNull)
            .column("updated_at",      type: .custom(SQLRaw("TIMESTAMP")))
            .run()
        try await database.create(index: "i_\(JobModel.schema)_state_queue_delayUntil")
            .on(JobModel.sqlTable)
            .column("state")
            .column("queue_name")
            .column("delay_until")
            .run()
    }
    
    // See `AsyncSQLMigration.revert(on:)`.
    public func revert(on database: any SQLDatabase) async throws {
        try await database.drop(table: JobModel.sqlTable).run()
        try await database.drop(enum: "\(JobModel.schema)_StoredJobStatus").run()
    }
}
