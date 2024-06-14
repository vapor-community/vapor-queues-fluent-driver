import class NIOCore.EventLoopFuture
import SQLKit
import protocol FluentKit.Database
import protocol FluentKit.AsyncMigration

/// Provides a database-independent way to express a date value representing "now".
struct SQLNow: SQLExpression {
    func serialize(to serializer: inout SQLSerializer) {
        switch serializer.dialect.name {
        case "sqlite": // For SQLite, write out the literal string 'now' (see below)
            SQLLiteral.string("now").serialize(to: &serializer)
        case "postgresql": // For Postgres, "current_timestamp" is a keyword, not a function, so use "now()" instead.
            SQLFunction("now").serialize(to: &serializer)
        default: // Everywhere else, just call the SQL standard function.
            SQLFunction("current_timestamp").serialize(to: &serializer)
        }
    }
}

/// Provides a wrapper which enables safely referring to expressions which should be interpreted as datetime
/// values when using the occasional database (**cough**SQLite**cough**) which doesn't do the right thing when
/// given such expressions as other databases do.
struct SQLDateValue<E: SQLExpression>: SQLExpression {
    static func now() -> Self where E == SQLNow { .init(.init()) }

    let value: E
    init(_ value: E) { self.value = value }

    func serialize(to serializer: inout SQLSerializer) {
        switch serializer.dialect.name {
        case "sqlite": // For SQLite, explicitly convert the inputs to UNIX timestamps
            SQLFunction("unixepoch", args: self.value).serialize(to: &serializer)
        default: // Everywhere else, this is a no-op passthrough waste of time.
            self.value.serialize(to: &serializer)
        }
    }
}

/// An alternative to `SQLLockingClause` which specifies the `SKIP LOCKED` modifier when the underlying database
/// supports it. As MySQL's and PostgreSQL's manuals both note, this should not be used except in very specific
/// scenarios, such as that of this package.
///
/// It is safe to use this expression with SQLite; its dialect correctly denies support for locking expressions.
enum SQLLockingClauseWithSkipLocked: SQLExpression {
    /// Request an exclusive "writer" lock, skipping rows that are already locked.
    case updateSkippingLocked

    /// Request a shared "reader" lock, skipping rows that are already locked.
    ///
    /// > Note: This is the "lightest" locking that is supported by both Postgres and MySQL.
    case shareSkippingLocked
    
    // See `SQLExpression.serialize(to:)`.
    func serialize(to serializer: inout SQLSerializer) {
        serializer.statement {
            switch self {
            case .updateSkippingLocked:
                guard $0.dialect.exclusiveSelectLockExpression != nil else { return }
                $0.append(SQLLockingClause.update)
            case .shareSkippingLocked:
                guard $0.dialect.sharedSelectLockExpression != nil else { return }
                $0.append(SQLLockingClause.share)
            }
            $0.append("SKIP LOCKED")
        }
    }
}

/// These overloads allow specifying various commonly-used `SQLExpression`s using more concise syntax. For example,
/// `.bind("hello")` rather than `SQLBind("hello")`, `.group(expr)` rather than `SQLGroupExpression(expr)`, etc.

extension SQLExpression {
    static func dateValue<E: SQLExpression>(_ value: E) -> Self where Self == SQLDateValue<E> { .init(value) }
    
    static func now() -> Self where Self == SQLDateValue<SQLNow> { .now() }

    static func function(_ name: String, _ args: any SQLExpression...) -> Self where Self == SQLFunction { .init(name, args: args) }
    
    static func group(_ expr: some SQLExpression) -> Self where Self == SQLGroupExpression { .init(expr) }

    static func identifier(_ str: some StringProtocol) -> Self where Self == SQLIdentifier { .init(String(str)) }

    static func column(_ name: some StringProtocol) -> Self where Self == SQLColumn { .init(String(name)) }
    static func column(_ name: some StringProtocol, table: some StringProtocol) -> Self where Self == SQLColumn { .init(String(name), table: String(table)) }
    static func column(_ name: some StringProtocol, table: some SQLExpression) -> Self where Self == SQLColumn { .column(.identifier(name), table: table) }
    static func column(_ name: some SQLExpression, table: some StringProtocol) -> Self where Self == SQLColumn { .column(name, table: .identifier(table)) }
    static func column(_ name: some SQLExpression, table: (any SQLExpression)? = nil)  -> Self where Self == SQLColumn { .init(name, table: table) }

    static func bind(_ value: some Encodable & Sendable) -> Self where Self == SQLBind { .init(value) }

    static func literal(_ val: some RawRepresentable<String>) -> Self where Self == SQLLiteral { .literal(val.rawValue) }
    static func literal(_ str: some StringProtocol) -> Self where Self == SQLLiteral { .string(String(str)) }
    static func literal(_ str: (some StringProtocol)?) -> Self where Self == SQLLiteral {  str.map { .string(String($0)) } ?? .null }
    static func literal(_ int: some FixedWidthInteger) -> Self where Self == SQLLiteral { .numeric("\(int)") }
    static func literal(_ int: (some FixedWidthInteger)?) -> Self where Self == SQLLiteral {  int.map { .numeric("\($0)") } ?? .null }
    static func literal(_ real: some BinaryFloatingPoint) -> Self where Self == SQLLiteral { .numeric("\(real)") }
    static func literal(_ real: (some BinaryFloatingPoint)?) -> Self where Self == SQLLiteral {  real.map { .numeric("\($0)") } ?? .null }
    static func literal(_ bool: Bool) -> Self where Self == SQLLiteral { .boolean(bool) }
    static func literal(_ bool: Bool?) -> Self where Self == SQLLiteral {  bool.map { .boolean($0) } ?? .null }

    static func null() -> Self where Self == SQLLiteral { .null }
}

/// The following extension allows using `Database's` `transaction(_:)` wrapper with an `SQLDatabase`.
extension SQLDatabase {
    func transaction<T>(_ closure: @escaping @Sendable (any SQLDatabase) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        guard let fluentSelf = self as? any Database else { fatalError("Cannot use `SQLDatabase.transaction(_:)` on a non-Fluent database.") }
        
        return fluentSelf.transaction { fluentTransaction in closure(fluentTransaction as! any SQLDatabase) }
    }

    func transaction<T>(_ closure: @escaping @Sendable (any SQLDatabase) async throws -> T) async throws -> T {
        guard let fluentSelf = self as? any Database else { fatalError("Cannot use `SQLDatabase.transaction(_:)` on a non-Fluent database.") }
        
        return try await fluentSelf.transaction { fluentTransaction in try await closure(fluentTransaction as! any SQLDatabase) }
    }
}

/// A variant of `AsyncMigration` designed to simplify using SQLKit to write migrations.
///
/// > Warning: Use of ``AsyncSQLMigration`` will cause runtime errors if the migration is added to a Fluent
/// > database which is not compatible with SQLKit (such as MongoDB).
public protocol AsyncSQLMigration: AsyncMigration {
    /// Perform the desired migration.
    ///
    /// - Parameter database: The database to migrate.
    func prepare(on database: any SQLDatabase) async throws
    
    /// Reverse, if possible, the migration performed by ``prepare(on:)-7nlxz``.
    ///
    /// It is not uncommon for a given migration to be lossy if run in reverse, or to be irreversible in the
    /// entire. While it is recommended that such a migration throw an error (thus stopping any further progression
    /// of the revert operation), there is no requirement that it do so. In practice, most irreversible migrations
    /// choose to simply do nothing at all in this method. Implementors should carefully consider the consequences
    /// of progressively older migrations attempting to revert themselves afterwards before leaving this method blank.
    ///
    /// - Parameter database: The database to revert.
    func revert(on database: any SQLDatabase) async throws
}

extension AsyncSQLMigration {
    public func prepare(on database: any Database) async throws {
        try await self.prepare(on: database as! any SQLDatabase)
    }
    
    public func revert(on database: any Database) async throws {
        try await self.revert(on: database as! any SQLDatabase)
    }
}
