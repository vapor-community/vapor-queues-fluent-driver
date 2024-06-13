import XCTest
import XCTVapor
import FluentKit
import Logging
import SQLKit
@testable import QueuesFluentDriver
@preconcurrency import Queues
#if canImport(FluentSQLiteDriver)
import FluentSQLiteDriver
#endif
#if canImport(FluentPostgresDriver)
import FluentPostgresDriver
#endif
#if canImport(FluentMySQLDriver)
import FluentMySQLDriver
#endif
import NIOSSL

final class QueuesFluentDriverTests: XCTestCase {
    var dbid: DatabaseID { .init(string: "sqlite") }
    var app: Application!
    
    private func useDbs(_ app: Application) throws {
        #if canImport(FluentSQLiteDriver)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        #endif
        #if canImport(FluentPostgresDriver)
        app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "test_username",
            password: Environment.get("DATABASE_PASSWORD") ?? "test_password",
            database: Environment.get("DATABASE_NAME") ?? "test_database",
            tls: .prefer(try .init(configuration: .clientDefault)))
        ), as: .psql)
        #endif
        #if canImport(FluentMySQLDriver)
        var config = TLSConfiguration.clientDefault
        config.certificateVerification = .none
        app.databases.use(DatabaseConfigurationFactory.mysql(configuration: .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "test_username",
            password: Environment.get("DATABASE_PASSWORD") ?? "test_password",
            database: Environment.get("DATABASE_NAME") ?? "test_database",
            tlsConfiguration: config
        )), as: .mysql)
        #endif
    }
    
    func testApplication() async throws {
        self.app.migrations.add(JobModelMigration(), to: self.dbid)
        
        let email = Email()
        self.app.queues.add(email)

        self.app.queues.use(.fluent(self.dbid))
        
        try await self.app.autoMigrate()

        self.app.get("send-email") { req in
            req.queue.dispatch(Email.self, .init(to: "tanner@vapor.codes"))
                .map { HTTPStatus.ok }
        }

        try await self.app.testable().test(.GET, "send-email") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        
        XCTAssertEqual(email.sent, [])
        try await self.app.queues.queue.worker.run().get()
        XCTAssertEqual(email.sent, [.init(to: "tanner@vapor.codes")])
        
        try await self.app.autoRevert()
    }
    
    func testFailedJobLoss() async throws {
        self.app.queues.add(FailingJob())
        self.app.queues.use(.fluent(self.dbid))
        self.app.migrations.add(JobModelMigration(), to: self.dbid)
        try await self.app.autoMigrate()

        let jobId = JobIdentifier()
        self.app.get("test") { req in
            req.queue.dispatch(FailingJob.self, ["foo": "bar"], id: jobId)
                .map { HTTPStatus.ok }
        }

        try await self.app.testable().test(.GET, "test") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        
        await XCTAssertThrowsErrorAsync(try await self.app.queues.queue.worker.run().get()) {
            XCTAssert($0 is FailingJob.Failure)
        }
        
        await XCTAssertNotNilAsync(try await (self.app.databases.database(self.dbid, logger: .init(label: ""), on: self.app.eventLoopGroup.any())! as! any SQLDatabase)
            .select().columns("*").from(JobModel.schema).where("id", .equal, jobId.string).first())
            
        try await self.app.autoRevert()
    }
    
    func testDelayedJobIsRemovedFromProcessingQueue() async throws {
        self.app.queues.add(DelayedJob())

        self.app.queues.use(.fluent(self.dbid))

        self.app.migrations.add(JobModelMigration(), to: self.dbid)
        try await self.app.autoMigrate()

        let jobId = JobIdentifier()
        self.app.get("delay-job") { req in
            req.queue.dispatch(DelayedJob.self, .init(name: "vapor"),
                               delayUntil: Date().addingTimeInterval(3600),
                               id: jobId)
                .map { HTTPStatus.ok }
        }

        try await self.app.testable().test(.GET, "delay-job") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        
        await XCTAssertEqualAsync(try await (self.app.databases.database(self.dbid, logger: .init(label: ""), on: self.app.eventLoopGroup.any())! as! any SQLDatabase)
            .select().columns("*").from(JobModel.schema).where("id", .equal, jobId.string)
            .first(decoding: JobModel.self, keyDecodingStrategy: .convertFromSnakeCase)?.state, .pending)
        
        try await self.app.autoRevert()
    }
    
    func testCoverageForFailingQueue() {
        let queue = FailingQueue(
            failure: QueuesFluentError.unsupportedDatabase,
            context: .init(queueName: .init(string: ""), configuration: .init(), application: self.app, logger: .init(label: ""), on: self.app.eventLoopGroup.any())
        )
        XCTAssertThrowsError(try queue.get(.init()).wait())
        XCTAssertThrowsError(try queue.set(.init(), to: JobData(payload: [], maxRetryCount: 0, jobName: "", delayUntil: nil, queuedAt: .init())).wait())
        XCTAssertThrowsError(try queue.clear(.init()).wait())
        XCTAssertThrowsError(try queue.push(.init()).wait())
        XCTAssertThrowsError(try queue.pop().wait())
    }
    
    override func setUp() async throws {
        XCTAssert(isLoggingConfigured)
        
        self.app = try await Application.make(.testing)
        try self.useDbs(self.app)
    }
    
    override func tearDown() async throws {
        try await self.app.asyncShutdown()
        self.app = nil
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

func XCTAssertEqualAsync<T>(
    _ expression1: @autoclosure () async throws -> T,
    _ expression2: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async where T: Equatable {
    do {
        let expr1 = try await expression1(), expr2 = try await expression2()
        return XCTAssertEqual(expr1, expr2, message(), file: file, line: line)
    } catch {
        return XCTAssertEqual(try { () -> Bool in throw error }(), false, message(), file: file, line: line)
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ callback: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTAssertThrowsError({}(), message(), file: file, line: line, callback)
    } catch {
        XCTAssertThrowsError(try { throw error }(), message(), file: file, line: line, callback)
    }
}

func XCTAssertNotNilAsync(
    _ expression: @autoclosure () async throws -> Any?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let result = try await expression()
        XCTAssertNotNil(result, message(), file: file, line: line)
    } catch {
        return XCTAssertNotNil(try { throw error }(), message(), file: file, line: line)
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
