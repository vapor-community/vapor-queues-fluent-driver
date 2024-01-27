import SQLKit
import FluentKit

struct ReturningClausePopQuery: PopQueryProtocol {
    static func pop(db: any Database, select: SQLSelectBuilder) async throws -> String? {
        try await (db as! any SQLDatabase).update(JobModel.schema)
            .set(JobModel.sqlColumn(\.$state), to: SQLBind(QueuesFluentJobState.processing))
            .set(JobModel.sqlColumn(\.$updatedAt), to: SQLFunction("now"))
            .where(JobModel.sqlColumn(\.$id), .equal, SQLGroupExpression(select.query))
            .returning(JobModel.sqlColumn(\.$id))
            .first(decodingColumn: "\(FieldKey.id)", as: String.self)
    }
}
