@preconcurrency import struct Queues.JobIdentifier

enum QueuesFluentError: Error {
    /// The queues system attempted to act on a job identifier which could not be found.
    case missingJob(JobIdentifier)

    /// The provided database is unsupported.
    ///
    /// This error is thrown if a non-SQL database (such as MongoDB) is specified.
    case unsupportedDatabase
}
