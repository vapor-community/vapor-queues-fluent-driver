import Foundation
import FluentKit
import Queues

/// Handles storage of a `JobData` into the database
final class JobDataModel: Fields {
    /// The job data to be encoded.
    @Field(key: "payload")
    var payload: [UInt8]
    
    /// The maxRetryCount for the `Job`.
    @Field(key: "max_retries")
    var maxRetryCount: Int
    
    /// The number of attempts made to run the `Job`.
    @Field(key: "attempt")
    var attempts: Int?
    
    /// A date to execute this job after
    @OptionalField(key: "delay_until")
    var delayUntil: Date?
    
    /// The date this job was queued
    @Field(key: "queued_at")
    var queuedAt: Date
    
    /// The name of the `Job`
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
