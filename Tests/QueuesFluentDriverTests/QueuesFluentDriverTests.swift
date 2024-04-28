import XCTest
import XCTVapor
import FluentKit
import Logging
@testable import QueuesFluentDriver
@preconcurrency import Queues
import FluentSQLiteDriver

final class QueuesFluentDriverTests: XCTestCase {
    func testApplication() throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(JobModelMigration())
        
        let email = Email()
        app.queues.add(email)

        app.queues.use(.fluent())
        
        try app.autoMigrate().wait()

        app.get("send-email") { req in
            req.queue.dispatch(Email.self, .init(to: "tanner@vapor.codes"))
                .map { HTTPStatus.ok }
        }

        try app.testable().test(.GET, "send-email") { res in
            XCTAssertEqual(res.status, .ok)
        }
        
        XCTAssertEqual(email.sent, [])
        try app.queues.queue.worker.run().wait()
        XCTAssertEqual(email.sent, [.init(to: "tanner@vapor.codes")])
    }
    
    func testFailedJobLoss() throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.queues.add(FailingJob())
        app.queues.use(.fluent())
        app.migrations.add(JobModelMigration())
        try app.autoMigrate().wait()

        let jobId = JobIdentifier()
        app.get("test") { req in
            req.queue.dispatch(FailingJob.self, ["foo": "bar"], id: jobId)
                .map { HTTPStatus.ok }
        }

        try app.testable().test(.GET, "test") { res in
            XCTAssertEqual(res.status, .ok)
        }
        
        XCTAssertThrowsError(try app.queues.queue.worker.run().wait()) {
            XCTAssert($0 is FailingJob.Failure)
        }
        
        XCTAssertNotNil(try (app.databases.database(logger: .init(label: ""), on: app.eventLoopGroup.any())! as! any SQLDatabase)
            .select().columns("*").from(JobModel.schema).where("id", .equal, jobId.string).first().wait())
    }
    
    func testDelayedJobIsRemovedFromProcessingQueue() throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        app.databases.use(.sqlite(.memory), as: .sqlite)

        app.queues.add(DelayedJob())

        app.queues.use(.fluent())

        app.migrations.add(JobModelMigration())
        try app.autoMigrate().wait()

        let jobId = JobIdentifier()
        app.get("delay-job") { req in
            req.queue.dispatch(DelayedJob.self, .init(name: "vapor"),
                               delayUntil: Date().addingTimeInterval(3600),
                               id: jobId)
                .map { HTTPStatus.ok }
        }

        try app.testable().test(.GET, "delay-job") { res in
            XCTAssertEqual(res.status, .ok)
        }
        
        XCTAssertEqual(try (app.databases.database(logger: .init(label: ""), on: app.eventLoopGroup.any())! as! any SQLDatabase)
            .select().columns("*").from(JobModel.schema).where("id", .equal, jobId.string)
            .first(decoding: JobModel.self, keyDecodingStrategy: .convertFromSnakeCase).wait()?.state, .pending)
    }
    
    override func setUp() {
        XCTAssert(isLoggingConfigured)
    }
}

final class Email: Job {
    struct Message: Codable, Equatable {
        let to: String
    }
    
    var sent: [Message] = []
    
    func dequeue(_ context: QueueContext, _ message: Message) -> EventLoopFuture<Void> {
        self.sent.append(message)
        context.logger.info("sending email \(message)")
        return context.eventLoop.makeSucceededFuture(())
    }
}

final class DelayedJob: Job {
    struct Message: Codable, Equatable {
        let name: String
    }
    
    func dequeue(_ context: QueueContext, _ message: Message) -> EventLoopFuture<Void> {
        context.logger.info("Hello \(message.name)")
        return context.eventLoop.makeSucceededFuture(())
    }
}

struct FailingJob: Job {
    struct Failure: Error {}
    
    func dequeue(_ context: QueueContext, _ message: [String: String]) -> EventLoopFuture<Void> {
        context.eventLoop.makeFailedFuture(Failure())
    }
    
    func error(_ context: QueueContext, _ error: any Error, _ payload: [String: String]) -> EventLoopFuture<Void> {
        context.eventLoop.makeFailedFuture(Failure())
    }
}

func env(_ name: String) -> String? {
    return ProcessInfo.processInfo.environment[name]
}

let isLoggingConfigured: Bool = {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel = env("LOG_LEVEL").flatMap { .init(rawValue: $0) } ?? .info
        return handler
    }
    return true
}()
