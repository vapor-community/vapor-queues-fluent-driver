import protocol SQLKit.SQLDatabase
import struct SQLKit.SQLRaw

public struct JobModelMigration: AsyncSQLMigration {
    /// Public initializer.
    public init() {}
    
    // See `AsyncSQLMigration.prepare(on:)`.
    public func prepare(on database: any SQLDatabase) async throws {
        let stateEnumType: String
        
        switch database.dialect.enumSyntax {
        case .typeName:
            stateEnumType = "\(JobModel.schema)_storedjobstatus"
            try await database.create(enum: stateEnumType)
                .value("pending")
                .value("processing")
                .run()
        case .inline:
            stateEnumType = "enum('\(StoredJobState.allCases.map(\.rawValue).joined(separator: "','"))')"
        default:
            stateEnumType = "varchar(16)"
        }

        try await database.create(table: JobModel.schema)
            .column("id",              type: .text,                          .primaryKey(autoIncrement: false))
            .column("queue_name",      type: .text,                          .notNull)
            .column("job_name",        type: .text,                          .notNull)
            .column("queued_at",       type: .timestamp,                     .notNull)
            .column("delay_until",     type: .timestamp)
            .column("state",           type: .custom(SQLRaw(stateEnumType)), .notNull)
            .column("max_retry_count", type: .int,                           .notNull)
            .column("attempts",        type: .int,                           .notNull)
            .column("payload",         type: .blob,                          .notNull)
            .column("updated_at",      type: .timestamp)
            .run()
        try await database.create(index: "i_\(JobModel.schema)_state_queue_delayUntil")
            .on(JobModel.schema)
            .column("state")
            .column("queue_name")
            .column("delay_until")
            .run()
    }
    
    // See `AsyncSQLMigration.revert(on:)`.
    public func revert(on database: any SQLDatabase) async throws {
        try await database.drop(table: JobModel.schema).run()
        switch database.dialect.enumSyntax {
        case .typeName:
            try await database.drop(enum: "\(JobModel.schema)_storedjobstatus").run()
        default:
            break
        }
    }
}
