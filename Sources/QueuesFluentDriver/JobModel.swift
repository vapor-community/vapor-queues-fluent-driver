import struct Foundation.Date
import struct Foundation.Data
import struct Queues.JobData
import struct Queues.JobIdentifier
import struct Queues.QueueName

/// The state of a job currently stored in the database.
enum StoredJobState: String, Codable, CaseIterable {
    /// Job has been set up but is not yet ready to execute.
    case initial
    
    /// Job is ready to be picked up for execution.
    case pending
    
    /// Job is in progress.
    case processing

    /// Job is completed.
    ///
    /// > Note: This state is only used if the driver is configured to preserve completed jobs.
    case completed
}

/// Encapsulates a job's metadata and `JobData`.
struct JobModel: Codable, Sendable {
    /// The job identifier. Corresponds directly to a `JobIdentifier`.
    let id: String?
    
    /// The queue to which the job was dispatched. Corresponds directly to a `QueueName`.
    let queueName: String
    
    /// The name of the job.
    let jobName: String
    
    /// The date this job was queued.
    let queuedAt: Date
    
    /// An optional `Date` before which the job shall not run.
    let delayUntil: Date?
    
    /// The current state of the Job
    let state: StoredJobState
    
    /// The maximum retry count for the job.
    let maxRetryCount: Int
    
    /// The number of attempts made to run the job so far.
    let attempts: Int
    
    /// The job's payload.
    let payload: Data
    
    /// The standard automatic update tracking timestamp.
    let updatedAt: Date
    
    init(id: JobIdentifier, queue: QueueName, jobData: JobData) {
        self.id = id.string
        self.queueName = queue.string
        self.jobName = jobData.jobName
        self.queuedAt = jobData.queuedAt
        self.delayUntil = jobData.delayUntil
        self.state = .pending
        self.maxRetryCount = jobData.maxRetryCount
        self.attempts = jobData.attempts ?? 0
        self.payload = Data(jobData.payload)
        self.updatedAt = .init()
    }
}
