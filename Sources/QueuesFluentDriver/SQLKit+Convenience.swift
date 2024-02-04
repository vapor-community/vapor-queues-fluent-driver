import class NIOCore.EventLoopFuture
import SQLKit
import FluentKit
import FluentSQL // temporarily needed for SQLQualifiedTable, this will shortly be in SQLKit instead

/// Provides a database-independent way to express a date value representing "now".
struct SQLNow: SQLExpression {
    func serialize(to serializer: inout SQLSerializer) {
        switch serializer.dialect.name {
        case "sqlite": // For SQLite, write out the literal string 'now' (see below)
            SQLLiteral.string("now").serialize(to: &serializer)
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

/// An alternative of `SQLLockingClause` which specifies the `SKIP LOCKED` modifier when the underlying database
/// supports it. As MySQL's and PostgreSQL's manuals both note, this should not be used except in very specific
/// scenarios, such as that of this package.
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

extension SQLQueryFetcher {
    /// Returns the named column from all output rows, if any, decoded as a given type.
    func all<D: Decodable>(decodingColumn col: String, as: D.Type) -> EventLoopFuture<[D]> {
        self.all().flatMapEachThrowing { try $0.decode(column: col, as: D.self) }
    }

    /// Returns the named column from the first output row, if any, decoded as a given type.
    func first<D: Decodable>(decodingColumn col: String, as: D.Type) -> EventLoopFuture<D?> {
        self.first().optionalFlatMapThrowing { try $0.decode(column: col, as: D.self) }
    }

    /// Returns the named column from all output rows, if any, decoded as a given type.
    func all<D: Decodable>(decodingColumn col: String, as: D.Type) async throws -> [D] {
        try await self.all().map { try $0.decode(column: col, as: D.self) }
    }

    /// Returns the named column from the first output row, if any, decoded as a given type.
    func first<D: Decodable>(decodingColumn col: String, as: D.Type) async throws -> D? {
        try await self.first()?.decode(column: col, as: D.self)
    }
}

extension FluentKit.Fields {
    /// Returns the string used as the name of the database column for the Fluent property at the given keypath.
    static func key(for keypath: KeyPath<Self, some QueryAddressableProperty>) -> String {
        .init(describing: Self()[keyPath: keypath].queryablePath[0])
    }

    /// Returns the result of `Self.key(for: keypath)` suitably wrapped as an `SQLExpression`. This represents
    /// **only** the column's name; it is not a fully qualified reference of any kind.
    static func sqlColumnName(_ keypath: KeyPath<Self, some QueryAddressableProperty>) -> some SQLExpression {
        SQLIdentifier(Self.key(for: keypath))
    }
}

extension FluentKit.Schema {
    /// Returns a `SQLExpression` suitable for referring to this model, even if it is in a non-default space or
    /// is a `ModelAlias`. One might use this in `.from()` or `.join()`, for example.
    static var sqlTable: some SQLExpression {
        SQLQualifiedTable(Self.schemaOrAlias, space: Self.alias == nil ? Self.space : nil)
    }
    
    /// Returns a fully-qualified `SQLExpression` which unambiguously refers to the column corresponding to the
    /// Fluent property at the given keypath. This is suitable, for example, for use in `.where()`, `.orWhere()`,
    /// `.column()`, `.orderBy()`, `.groupBy()`, `.returning()`, etc. It is, however, _not_ always suitable for
    /// use within `.set()` clauses of update queries - use `sqlColumName(_:)` for that.
    static func sqlColumn(_ keypath: KeyPath<Self, some QueryAddressableProperty>) -> some SQLExpression {
        SQLColumn(Self.sqlColumnName(keypath), table: Self.sqlTable)
    }
}

/// These overloads allow specifying various commonly-used `SQLExpression`s using more concise syntax. For example,
/// `.bind("hello")` rather than `SQLBind("hello")`, `.group(expr)` rather than `SQLGroupExpression(expr)`, etc.

extension SQLExpression {
    static func dateValue<E: SQLExpression>(_ value: E) -> Self where Self == SQLDateValue<E> { .init(value) }
    
    static func now() -> Self where Self == SQLDateValue<SQLNow> { .now() }

    static func bind(_ value: some Encodable) -> Self where Self == SQLBind { .init(value) }
    
    static func function(_ name: String, _ args: any SQLExpression...) -> Self where Self == SQLFunction { .init(name, args: args) }
    
    static func group(_ expr: some SQLExpression) -> Self where Self == SQLGroupExpression { .init(expr) }
}

/// The following extensions are a rather plodding and pedantic series of repetitive overloads which enable writing
/// cleaner-looking SQLKit queries. For example:
///
///     sqlDb.select()
///         .column(MyModel.sqlColumn(\.$id))
///         .column(MyModel.sqlColumn(\.$name))
///         .column(MyModel.sqlColumn(\.$status))
///         .from(MyModel.sqlTable)
///         .where(MyModel.sqlColumn(\.$type), .equal, .bind(MyModelType.foo))
///
/// These overloads allow rewriting this query as:
///
///     sqlDb.select()
///         .column(\MyModel.$id)
///         .column(\MyModel.$name)
///         .column(\MyModel.$status)
///         .from(MyModel.self)
///         .where(\MyModel.$type, .equal, MyModelType.foo)
///
/// The overloads provided here are not even remotely a complete set; they provide only the minimum set needed to
/// support the queries found in `FluentQueue.swift`.

extension SQLSubqueryClauseBuilder {
    #if swift(>=5.9)
    @discardableResult
    func columns<each M: Schema, each V: QueryAddressableProperty>(_ kps: repeat KeyPath<each M, each V>) -> Self { repeat _ = self.column(each kps); return self }
    #else
    @discardableResult
    func columns<M: Schema, N: Schema, O: Schema, P: Schema, Q: Schema, R: Schema>(
        _ kp1: KeyPath<M, some QueryAddressableProperty>, _ kp2: KeyPath<N, some QueryAddressableProperty>, _ kp3: KeyPath<O, some QueryAddressableProperty>,
        _ kp4: KeyPath<P, some QueryAddressableProperty>, _ kp5: KeyPath<Q, some QueryAddressableProperty>, _ kp6: KeyPath<R, some QueryAddressableProperty>
    ) -> Self {
        self.columns(M.sqlColumn(kp1), N.sqlColumn(kp2), O.sqlColumn(kp3), P.sqlColumn(kp4), Q.sqlColumn(kp5), R.sqlColumn(kp6))
    }
    #endif
    @discardableResult
    func column<M: Schema>(_ kp: KeyPath<M, some QueryAddressableProperty>) -> Self { self.column(M.sqlColumn(kp)) }
    @discardableResult
    func from<M: Schema>(_: M.Type) -> Self { self.from(M.sqlTable) }
}
extension SQLPredicateBuilder {
    @discardableResult
    func `where`(_ kp: KeyPath<some Schema, some QueryAddressableProperty>, _ op: SQLBinaryOperator, _ rhs: some Encodable) -> Self { self.where(kp, op, .bind(rhs)) }
    @discardableResult
    func `where`<M: Schema>(_ kp: KeyPath<M, some QueryAddressableProperty>, _ op: SQLBinaryOperator, _ rhs: some SQLExpression) -> Self { self.where(M.sqlColumn(kp), op, rhs) }
}
extension SQLPartialResultBuilder {
    @discardableResult
    func orderBy<M: Schema>(_ kp: KeyPath<M, some QueryAddressableProperty>, _ dir: SQLDirection = .ascending) -> Self { self.orderBy(M.sqlColumn(kp), dir) }
}
extension SQLColumnUpdateBuilder {
    @discardableResult
    func set(_ kp: KeyPath<some Schema, some QueryAddressableProperty>, to bind: some Encodable) -> Self { self.set(kp, to: SQLBind(bind)) }
    @discardableResult
    func set<M: Schema>(_ kp: KeyPath<M, some QueryAddressableProperty>, to expr: some SQLExpression) -> Self { self.set(M.sqlColumnName(kp), to: expr) }
}
