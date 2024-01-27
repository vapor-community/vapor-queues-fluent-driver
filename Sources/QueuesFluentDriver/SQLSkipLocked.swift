import SQLKit

enum SQLSkipLocked: SQLExpression {
    case forUpdateSkipLocked
    case forShareSkipLocked
    
    func serialize(to serializer: inout SQLSerializer) {
        guard serializer.dialect.name != "sqlite" else {
            return
        }
        
        switch self {
        case .forUpdateSkipLocked:
            serializer.write("FOR UPDATE SKIP LOCKED")
        case .forShareSkipLocked:
            // This is the "lightest" locking that is supported by both Postgres and Mysql
            serializer.write("FOR SHARE SKIP LOCKED")
        }
    }
}
