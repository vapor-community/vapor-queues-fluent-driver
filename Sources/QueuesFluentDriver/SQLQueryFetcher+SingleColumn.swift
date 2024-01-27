import SQLKit

// TODO: This can be removed when these APIs land in SQLKit.
extension SQLQueryFetcher {
    /// Returns the named column from all output rows, if any, decoded as a given type.
    func all<D: Decodable>(decodingColumn column: String, as: D.Type) -> EventLoopFuture<[D]> {
        self.all().flatMapEachThrowing {
            try $0.decode(column: column, as: D.self)
        }
    }

    /// Returns the named column from the first output row, if any, decoded as a given type.
    func first<D: Decodable>(decodingColumn column: String, as: D.Type) -> EventLoopFuture<D?> {
        self.first().optionalFlatMapThrowing {
            try $0.decode(column: column, as: D.self)
        }
    }

    /// Returns the named column from all output rows, if any, decoded as a given type.
    func all<D: Decodable>(decodingColumn column: String, as: D.Type) async throws -> [D] {
        try await self.all().map { try $0.decode(column: column, as: D.self) }
    }

    /// Returns the named column from the first output row, if any, decoded as a given type.
    func first<D: Decodable>(decodingColumn column: String, as: D.Type) async throws -> D? {
        try await self.first()?.decode(column: column, as: D.self)
    }
}
