import SQLKit
import FluentKit

protocol PopQueryProtocol {
    static func pop(db: any Database, select: SQLSelectBuilder) async throws -> String?
}
