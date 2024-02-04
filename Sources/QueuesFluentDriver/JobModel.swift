import struct Foundation.Date
import FluentKit
import struct Queues.JobData
import struct Queues.JobIdentifier

/// The possible states of a job as stored in the database.
enum QueuesFluentJobState: String, Codable, CaseIterable {
    /// Ready to be picked up for execution
    case pending
    
    /// In progress
    case processing
    
    /// Executed, regardless if it was successful or not
    case completed
}

/// Encapsulates a job's metadata and `JobData`.
final class JobModel: Model {
    static let schema = "_jobs_meta"
    
    /// The unique Job ID
    @ID(custom: .id, generatedBy: .user)
    var id: String?
    
    /// The Job key
    @Field(key: "queue")
    var queue: String
    
    /// The current state of the Job
    @Enum(key: "state")
    var state: QueuesFluentJobState
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    /// The job data to be encoded.
    @Field(key: "payload")
    var payload: [UInt8]
    
    /// The maxRetryCount for the job.
    @Field(key: "max_retry_count")
    var maxRetryCount: Int
    
    /// The number of attempts made to run the job.
    @Field(key: "attempts")
    var attempts: Int
    
    /// A date to execute this job after.
    @OptionalField(key: "delay_until")
    var delayUntil: Date?
    
    /// The date this job was queued.
    @Field(key: "queued_at")
    var queuedAt: Date
    
    /// The name of the job.
    @Field(key: "job_name")
    var jobName: String
    
    init() {}
    
    init(id: JobIdentifier, queue: String, jobData: JobData) {
        self.id = id.string
        self.queue = queue
        self.state = .pending
        self.payload = jobData.payload
        self.maxRetryCount = jobData.maxRetryCount
        self.attempts = jobData.attempts ?? 0
        self.delayUntil = jobData.delayUntil
        self.jobName = jobData.jobName
        self.queuedAt = jobData.queuedAt
    }
}
