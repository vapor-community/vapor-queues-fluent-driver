@preconcurrency import SQLKit
import FluentKit

struct TransactionalPopQuery: PopQueryProtocol {
    /// In databases with no RETURNING clause support, not to mention those which cannot otherwise update and
    /// select in the same query  (such as MySQL), we must wrap the SELECT and UPDATE pair in a transaction instead.
    static func pop(db: any Database, select: SQLSelectBuilder) async throws -> String? {
        try await db.transaction { transaction -> String? in
            let database = transaction as! any SQLDatabase

            guard let id = try await select.first(decodingColumn: "\(FieldKey.id)", as: String.self) else {
                return nil
            }

            try await database
                .update(JobModel.sqlTable)
                .set(JobModel.sqlColumn(\.$state), to: SQLBind(QueuesFluentJobState.processing))
                .set(JobModel.sqlColumn(\.$updatedAt), to: SQLFunction("now"))
                .where(JobModel.sqlColumn(\.$id), .equal, SQLBind(id))
                .where(JobModel.sqlColumn(\.$state), .equal, SQLBind(QueuesFluentJobState.pending))
                .run()
            
            return id
        }
    }
}
