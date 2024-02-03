import struct Foundation.Date
import protocol FluentKit.Model
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

/// Encapsulates a job's metadata and the ``JobDataModel`` representing the `JobData`.
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
    
    @Timestamp(key: "deleted_at", on: .delete)
    var deletedAt: Date?
    
    @Group(key: "data")
    var data: JobDataModel
    
    init() {}
    
    init(id: JobIdentifier, queue: String, jobData: JobDataModel) {
        self.id = id.string
        self.queue = queue
        self.state = .pending
        self.data = jobData
    }
}
