import struct Foundation.Date
import FluentKit
import struct Queues.JobData
import struct Queues.JobIdentifier
import struct Queues.QueueName

/// The various states of a job currently stored in the database.
enum StoredJobState: String, Codable, CaseIterable {
    /// Job is ready to be picked up for execution.
    case pending
    
    /// Job is in progress.
    case processing
    
    /// Job has finished, whether successfully or not.
    case completed
}

/// Encapsulates a job's metadata and `JobData`.
final class JobModel: Model {
    // See `Model.schema`.
    static let schema = "_jobs_meta"
    
    /// The job identifier. Corresponds directly to a `JobIdentifier`.
    @ID(custom: .id, generatedBy: .user)
    var id: String?
    
    /// The queue to which the job was dispatched. Corresponds directly to a `QueueName`.
    @Field(key: "queue_name")
    var queue: String
    
    /// The name of the job.
    @Field(key: "job_name")
    var jobName: String
    
    /// The date this job was queued.
    @Field(key: "queued_at")
    var queuedAt: Date
    
    /// An optional `Date` before which the job shall not run.
    @Timestamp(key: "delay_until", on: .none)
    var delayUntil: Date?
    
    /// The current state of the Job
    @Enum(key: "state")
    var state: StoredJobState
    
    /// The maximum retry count for the job.
    @Field(key: "max_retry_count")
    var maxRetryCount: Int
    
    /// The number of attempts made to run the job so far.
    @Field(key: "attempts")
    var attempts: Int
    
    /// The job's payload.
    @Field(key: "payload")
    var payload: [UInt8]
    
    /// The standard automatic update tracking timestamp.
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() {}
    
    init(id: JobIdentifier, queue: QueueName, jobData: JobData) {
        self.id = id.string
        self.queue = queue.string
        self.jobName = jobData.jobName
        self.queuedAt = jobData.queuedAt
        self.delayUntil = jobData.delayUntil
        self.state = .pending
        self.maxRetryCount = jobData.maxRetryCount
        self.attempts = jobData.attempts ?? 0
        self.payload = jobData.payload
        self.updatedAt = .some(.init())
    }
}
