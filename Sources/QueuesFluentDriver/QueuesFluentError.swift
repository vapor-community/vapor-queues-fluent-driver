@preconcurrency import struct Queues.JobIdentifier

enum QueuesFluentError: Error {
    /// Couldn't find a job with this Id
    case missingJob(_ id: JobIdentifier)

    /// The JobIdentifier is not a valid UUID
    case invalidIdentifier

    /// Error encoding the job payload to JSON
    case jobDataEncodingError(_ message: String? = nil)

    /// Error decoding the job payload from JSON
    case jobDataDecodingError(_ message: String? = nil)

    /// The given DatabaseID doesn't match any existing database configured in the Vapor app.
    case databaseNotFound
    
    /// The provided `DatabaseID` refers to database which is unsupported.
    case unsupportedDatabase
}
