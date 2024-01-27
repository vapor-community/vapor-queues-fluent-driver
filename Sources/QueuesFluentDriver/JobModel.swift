import Foundation
import FluentKit
import Queues

public enum QueuesFluentJobState: String, Codable, CaseIterable {
    /// Ready to be picked up for execution
    case pending
    
    /// In progress
    case processing
    
    /// Executed, regardless if it was successful or not
    case completed
}

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
    
    /// Earliest date the job can run
    @OptionalField(key: "run_at")
    var runAtOrAfter: Date?
    
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
