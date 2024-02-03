import protocol SQLKit.SQLExpression
import struct SQLKit.SQLSerializer
import enum SQLKit.SQLLockingClause

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
