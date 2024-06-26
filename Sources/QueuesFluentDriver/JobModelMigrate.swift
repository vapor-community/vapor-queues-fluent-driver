import protocol SQLKit.SQLDatabase
import enum SQLKit.SQLColumnConstraintAlgorithm
import enum SQLKit.SQLDataType
import enum SQLKit.SQLLiteral
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

        /// This whole pile of nonsense is only here because of
        /// https://dev.mysql.com/doc/refman/5.7/en/server-system-variables.html#sysvar_explicit_defaults_for_timestamp
        /// In short, I'm making things work in MySQL 5.7 as a favor to a colleague.
        let manualTimestampType: SQLDataType, autoTimestampConstraints: [SQLColumnConstraintAlgorithm]

        switch database.dialect.name {
        case "mysql":
            manualTimestampType = .custom(SQLRaw("DATETIME"))
            autoTimestampConstraints = [.custom(SQLLiteral.null), .default(SQLLiteral.null)]
        default:
            manualTimestampType = .timestamp
            autoTimestampConstraints = []
        }

        try await database.create(table: JobModel.schema)
            .column("id",              type: .text,                          .primaryKey(autoIncrement: false))
            .column("queue_name",      type: .text,                          .notNull)
            .column("job_name",        type: .text,                          .notNull)
            .column("queued_at",       type: manualTimestampType,            .notNull)
            .column("delay_until",     type: manualTimestampType,            .default(SQLLiteral.null))
            .column("state",           type: .custom(SQLRaw(stateEnumType)), .notNull)
            .column("max_retry_count", type: .int,                           .notNull)
            .column("attempts",        type: .int,                           .notNull)
            .column("payload",         type: .blob,                          .notNull)
            .column("updated_at",      type: .timestamp,                     autoTimestampConstraints)
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
