import FluentKit
import Logging
import SQLKit

/// A migration to upgrade the data from the old 1.x and 2.x versions of this driver to the current version.
///
/// This migration is compatible with all known released versions of the driver. It is _not_ compatible with any
/// of the 3.x-beta tags. It is known to be compatible with MySQL 8.0+, PostgreSQL 11+, and SQLite 3.38.0+, and to be
/// _incompatible_ with MySQL 5.7 and earlier.
///
/// Once run, this migration is not reversible. See discussion in ``JobModelOldFormatMigration/revert(on:)-3xv3q`` for
/// more details. This migration should be used **_in place of_** ``JobModelMigration``, not in addition to it. Using
/// both migrations will cause database errors. If an error occurs during migration, a reasonable attempt is made to
/// restore everything to its original state. Even under extreme conditions, the original data is guaranteed to remain
/// intact until the migration is succesfully completed; the original data is never modified, and is deleted only after
/// everything has finished without errors.
///
/// > Note: The `payload` format used by the MySQL-specific logic is a bit bizarre; instead of the plain binary string
/// > used for the other databases, MySQL's version is Base64-encoded and double-quoted. This is an artifact of the
/// > missing conformance of `Data` to `MySQLDataConvertible` in `MySQLNIO`, a bug that cannot be fixed at the present
/// > time without causing problematic behavioral changes.
public struct JobModelOldFormatMigration: AsyncSQLMigration {
    private let jobsTableName: String
    private let jobsTableSpace: String?

    /// Public initializer.
    public init(
        jobsTableName: String = "_jobs_meta",
        jobsTableSpace: String? = nil
    ) {
        self.jobsTableName = jobsTableName
        self.jobsTableSpace = jobsTableSpace
    }

    // See `AsyncSQLMigration.prepare(on:)`.
    public func prepare(on database: any SQLDatabase) async throws {
        /// Return a `SQLQueryString` which extracts the field with the given name from the old-format "data" JSON as the given type.
        func dataGet(_ name: String, as type: String) -> SQLQueryString {
            switch database.dialect.name {
            case "postgresql": "((convert_from(\"data\", 'UTF8')::jsonb)->>\(literal: name))::\(unsafeRaw: type == "double" ? "double precision" : type)"
            case "mysql":      "json_value(convert(data USING utf8mb4), \(literal: "$.\(name)") RETURNING \(unsafeRaw: type == "text" ? "CHAR" : (type == "double" ? "DOUBLE" : "SIGNED")))"
            case "sqlite":     "data->>\(literal: "$.\(name)")"
            default: ""
            }
        }
        /// Return a `SQLQueryString` which extracts the timestamp field with the given name from the old-format "data" JSON as a UNIX
        /// timestamp, compensating for the difference between the UNIX epoch and Date's reference date (978,307,200 seconds).
        func dataTimestamp(_ name: String) -> SQLQueryString {
            switch database.dialect.name {
            case "postgresql": "to_timestamp(\(dataGet(name, as: "double")) + 978307200.0)"
            case "mysql":      "from_unixtime(\(dataGet(name, as: "double")) + 978307200.0)"
            case "sqlite":     "\(dataGet(name, as: "double")) + 978307200.0"
            default: ""
            }
        }
        /// Return a `SQLQueryString` which extracts the payload from the old-format "data" JSON, converting the original array of one-byte
        /// integers to the database's appropriate binary representation (`bytea` for Postgres, `BINARY` collation with Base64 encoding and
        /// surrounding quotes for MySQL (don't ask...), `BLOB` affinity for SQLite).
        func dataPayload() -> SQLQueryString {
            switch database.dialect.name {
            case "postgresql": #"coalesce((SELECT decode(string_agg(lpad(to_hex(b::int), 2, '0'), ''), 'hex') FROM jsonb_array_elements_text((convert_from("data", 'UTF8')::jsonb)->'payload') AS a(b)), '\x')"#
            case "mysql":      #"coalesce((SELECT /*+SET_VAR(group_concat_max_len=1048576)*/ concat('"',to_base64(group_concat(char(b) SEPARATOR '')),'"') FROM json_table(convert(data USING utf8mb4), '$.payload[*]' COLUMNS (b INT PATH '$')) t), X'')"#
            case "sqlite":     #"coalesce((SELECT unhex(group_concat(format('%02x',b.value), '')) FROM json_each(data, '$.payload') as b), '')"#
            default: ""
            }
        }

        // Make sure that we keep the old table in the same space when we move it aside.
        let tempTable = SQLQualifiedTable("_temp_old_\(self.jobsTableName)", space: self.jobsTableSpace)
        let jobsTable = SQLQualifiedTable(self.jobsTableName, space: self.jobsTableSpace)
        let enumType = SQLQualifiedTable("\(self.jobsTableName)_storedjobstatus", space: self.jobsTableSpace)

        // 1. Rename the existing table so we can create the new format in its place.
        try await database.alter(table: jobsTable).rename(to: tempTable).run()

        do {
            // 2. Run the "real" migration to create the correct table structure and any associated objects.
            try await JobModelMigration(jobsTableName: self.jobsTableName, jobsTableSpace: self.jobsTableSpace).prepare(on: database)

            // 3. Migrate the data from the old table.
            try await database.insert(into: jobsTable)
                .columns("id", "queue_name", "job_name", "queued_at", "delay_until", "state", "max_retry_count", "attempts", "payload", "updated_at")
                .select { $0
                    .column("job_id")
                    .column("queue")
                    .column(.function("coalesce", dataGet("jobName", as: "text"), .literal("")))
                    .column(.function("coalesce", dataTimestamp("queuedAt"), .identifier("created_at")))
                    .column(dataTimestamp("delayUntil"))
                    .column(database.dialect.name == "postgresql" ? "state::\(enumType)" as SQLQueryString : "state")
                    .column(.function("coalesce", dataGet("maxRetryCount", as: "bigint"), .literal(0)))
                    .column(.function("coalesce", dataGet("attempts", as: "bigint"), .literal(0)))
                    .column(dataPayload())
                    .column("updated_at")
                    .from(tempTable)
                }
                .run()
        } catch {
            // Attempt to clean up after ourselves by deleting the new table and moving the old one back into place.
            try? await database.drop(table: jobsTable).run()
            try? await database.alter(table: tempTable).rename(to: jobsTable).run()
            throw error
        }

        // 4. Drop the old table.
        try await database.drop(table: tempTable).run()
    }

    // See `AsyncSQLMigration.revert(on:)`.
    public func revert(on database: any SQLDatabase) async throws {
        /// This migration technically can be reverted, if one is willing to consider the values of the original
        /// `id`, `created_at`, and `deleted_at` columns spurious, and therefore disposable. However, it would be
        /// a good deal of work - in particular, turning the binary payload back into a JSON byte array would
        /// even more involved than the frontways conversion, and the utility of doing so is insufficient to
        /// justify the effort unless this feature ends up being commonly requested. We could call through to
        /// ``JobModelMigration``'s revert, but it seems best to err on the side of caution for this migration.

        // TODO: Should we throw an error instead of logging an easily-missed message?
        database.logger.warning("Reverting the \(self.name) migration is not implemented; your job metadata table is unchanged!")
    }
}
