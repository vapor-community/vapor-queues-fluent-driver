import struct Foundation.Date
import protocol FluentKit.Fields
import struct Queues.JobData

/// Encapsulates a `JobData` struct as a set of Fluent fields; see also ``JobModel``.
final class JobDataModel: Fields {
    /// The job data to be encoded.
    @Field(key: "payload")
    var payload: [UInt8]
    
    /// The maxRetryCount for the job.
    @Field(key: "max_retry_count")
    var maxRetryCount: Int
    
    /// The number of attempts made to run the job.
    @Field(key: "attempts")
    var attempts: Int?
    
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
    
    init(jobData: JobData) {
        self.payload = jobData.payload
        self.maxRetryCount = jobData.maxRetryCount
        self.attempts = jobData.attempts
        self.delayUntil = jobData.delayUntil
        self.jobName = jobData.jobName
        self.queuedAt = jobData.queuedAt
    }
}
