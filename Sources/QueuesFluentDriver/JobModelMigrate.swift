import SQLKit

public struct JobModelMigration: AsyncSQLMigration {
    private let jobsTableString: String
    private let jobsTable: SQLQualifiedTable

    /// Public initializer.
    public init(
        jobsTableName: String = "_jobs_meta",
        jobsTableSpace: String? = nil
    ) {
        self.jobsTableString = "\(jobsTableSpace.map { "\($0)_" } ?? "")\(jobsTableName)"
        self.jobsTable = .init(jobsTableName, space: jobsTableSpace)
    }

    // See `AsyncSQLMigration.prepare(on:)`.
    public func prepare(on database: any SQLDatabase) async throws {
        let stateEnumType: any SQLExpression

        switch database.dialect.enumSyntax {
        case .typeName:
            stateEnumType = .identifier("\(self.jobsTableString)_storedjobstatus")
            var builder = database.create(enum: stateEnumType)
            builder = StoredJobState.allCases.reduce(builder, { $0.value($1.rawValue) })
            try await builder.run()
        case .inline:
             // This is technically a misuse of SQLFunction, but it produces the correct syntax
            stateEnumType = .function("enum", StoredJobState.allCases.map { .literal($0.rawValue) })
        default:
            // This is technically a misuse of SQLFunction, but it produces the correct syntax
            stateEnumType = .function("varchar", .literal(16))
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

        try await database.create(table: self.jobsTable)
            .column("id",              type: .text,                  .primaryKey(autoIncrement: false))
            .column("queue_name",      type: .text,                  .notNull)
            .column("job_name",        type: .text,                  .notNull)
            .column("queued_at",       type: manualTimestampType,    .notNull)
            .column("delay_until",     type: manualTimestampType,    .default(SQLLiteral.null))
            .column("state",           type: .custom(stateEnumType), .notNull)
            .column("max_retry_count", type: .int,                   .notNull)
            .column("attempts",        type: .int,                   .notNull)
            .column("payload",         type: .blob,                  .notNull)
            .column("updated_at",      type: .timestamp,             autoTimestampConstraints)
            .run()
        try await database.create(index: "i_\(self.jobsTableString)_state_queue_delayUntil")
            .on(self.jobsTable)
            .column("state")
            .column("queue_name")
            .column("delay_until")
            .run()
    }
    
    // See `AsyncSQLMigration.revert(on:)`.
    public func revert(on database: any SQLDatabase) async throws {
        try await database.drop(table: self.jobsTable).run()
        switch database.dialect.enumSyntax {
        case .typeName:
            try await database.drop(enum: "\(self.jobsTableString)_storedjobstatus").run()
        default:
            break
        }
    }
}
