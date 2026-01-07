import struct Queues.JobIdentifier
import struct Queues.QueueName

extension Queues.JobIdentifier: @retroactive Codable {
    public init(from decoder: any Decoder) throws {
        self.init(string: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.string)
    }
}

extension Queues.QueueName: @retroactive Codable {
    public init(from decoder: any Decoder) throws {
        self.init(string: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.string)
    }
}
