import SQLKit

public struct JobModelMigration: AsyncSQLMigration {
    private let jobsTable: SQLQualifiedTable
    private let jobsTableIndexName: String
    private let stateEnumType: SQLQualifiedTable // "table" is a bit of a misnomer here, but the expression still does the right thing
    private let oldStateEnumName: String?

    /// Public initializer.
    public init(
        jobsTableName: String = "_jobs_meta",
        jobsTableSpace: String? = nil
    ) {
        self.jobsTable = SQLQualifiedTable(jobsTableName, space: jobsTableSpace)
        self.jobsTableIndexName = "i_\(jobsTableName)_state_queue_delayuntil"
        self.stateEnumType = SQLQualifiedTable("\(jobsTableName)_storedjobstatus", space: jobsTableSpace)
        self.oldStateEnumName = jobsTableSpace.map { "\($0)_\(jobsTableName)_storedjobstatus" }
    }

    // See `AsyncSQLMigration.prepare(on:)`.
    public func prepare(on database: any SQLDatabase) async throws {
        let actualStateEnumType: SQLDataType

        switch database.dialect.enumSyntax {
        case .typeName:
            var builder = database.create(enum: self.stateEnumType)
            builder = StoredJobState.allCases.reduce(builder, { $0.value($1.rawValue) })
            try await builder.run()
            actualStateEnumType = .custom(self.stateEnumType)
        case .inline:
            actualStateEnumType = .custom(SQLEnumDataType(cases: StoredJobState.allCases.map { .literal($0.rawValue) }))
        default:
            // This is technically a misuse of SQLFunction, but it produces the correct syntax
            actualStateEnumType = .custom(.function("varchar", .literal(16)))
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
            .column("id",              type: .text,               .primaryKey(autoIncrement: false))
            .column("queue_name",      type: .text,               .notNull)
            .column("job_name",        type: .text,               .notNull)
            .column("queued_at",       type: manualTimestampType, .notNull)
            .column("delay_until",     type: manualTimestampType, .default(SQLLiteral.null))
            .column("state",           type: actualStateEnumType, .notNull)
            .column("max_retry_count", type: .int,                .notNull)
            .column("attempts",        type: .int,                .notNull)
            .column("payload",         type: .blob,               .notNull)
            .column("updated_at",      type: .timestamp,          autoTimestampConstraints)
            .run()
        try await database.create(index: self.jobsTableIndexName)
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
            // In version 3.0.1 and earlier of the driver, if a space was specified, the enum's name was different,
            // and the enum ended up in the default space rather than the one given. For compatibility, we need to drop
            // the old name from the default space. Fortunately, `DROP TYPE` supports `IF EXISTS`.
            if let oldStateEnumName = self.oldStateEnumName {
                try await database.drop(enum: oldStateEnumName).ifExists().run()
            }

            try await database.drop(enum: self.stateEnumType).ifExists().run()
        default:
            break
        }
    }
}
