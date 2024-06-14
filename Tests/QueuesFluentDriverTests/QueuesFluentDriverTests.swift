import XCTest
import XCTVapor
import FluentKit
import Logging
import SQLKit
import ConsoleKitTerminal
@testable import QueuesFluentDriver
import Queues
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
    var app: Application!
    var dbid: DatabaseID!

    private func useDbs(_ app: Application) throws {
        #if canImport(FluentSQLiteDriver)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        #endif

        #if canImport(FluentPostgresDriver)
        app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
            hostname: env("POSTGRES_HOST")     ?? env("DATABASE_HOST")     ?? "localhost",
            port:     (env("POSTGRES_PORT")    ?? env("DATABASE_PORT")).flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
            username: env("POSTGRES_USERNAME") ?? env("DATABASE_USERNAME") ?? "test_username",
            password: env("POSTGRES_PASSWORD") ?? env("DATABASE_PASSWORD") ?? "test_password",
            database: env("POSTGRES_NAME")     ?? env("DATABASE_NAME")     ?? "test_database",
            tls: .prefer(try .init(configuration: .clientDefault)))
        ), as: .psql)
        #endif

        #if canImport(FluentMySQLDriver)
        var config = TLSConfiguration.clientDefault
        config.certificateVerification = .none
        app.databases.use(DatabaseConfigurationFactory.mysql(configuration: .init(
            hostname: env("MYSQL_HOST")     ?? env("DATABASE_HOST")     ?? "localhost",
            port:     (env("MYSQL_PORT")    ?? env("DATABASE_PORT")).flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
            username: env("MYSQL_USERNAME") ?? env("DATABASE_USERNAME") ?? "test_username",
            password: env("MYSQL_PASSWORD") ?? env("DATABASE_PASSWORD") ?? "test_password",
            database: env("MYSQL_NAME")     ?? env("DATABASE_NAME")     ?? "test_database",
            tlsConfiguration: config
        )), as: .mysql)
        #endif
    }

    private func withEachDatabase(_ closure: () async throws -> Void) async throws {
        func run(_ dbid: DatabaseID) async throws {
            self.dbid = dbid
            self.app = try await Application.make(.testing)
            self.app.logger[metadataKey: "test-dbid"] = "\(dbid.string)"

            try self.useDbs(self.app)
            self.app.migrations.add(JobModelMigration(), to: self.dbid)
            self.app.queues.use(.fluent(self.dbid))

            try await self.app.autoMigrate()

            do { try await closure() }
            catch {
                try? await self.app.autoRevert()
                try? await self.app.asyncShutdown()
                throw error
            }

            try await self.app.autoRevert()
            try await self.app.asyncShutdown()
            self.app = nil
        }

        #if canImport(FluentSQLiteDriver)
        try await run(.sqlite)
        #endif

        #if canImport(FluentPostgresDriver)
        try await run(.psql)
        #endif

        #if canImport(FluentMySQLDriver)
        try await run(.mysql)
        #endif
    }

    func testApplication() async throws { try await self.withEachDatabase {
        let email = Email()

        self.app.queues.add(email)
        self.app.get("send-email") { req in
            try await req.queue.dispatch(Email.self, .init(to: "gwynne@vapor.codes"))
            return HTTPStatus.ok
        }

        try await self.app.testable().test(.GET, "send-email") { res async in
            XCTAssertEqual(res.status, .ok)
        }

        await XCTAssertEqualAsync(await email.sent, [])
        try await self.app.queues.queue.worker.run().get()
        await XCTAssertEqualAsync(await email.sent, [.init(to: "gwynne@vapor.codes")])
    } }

    func testFailedJobLoss() async throws { try await self.withEachDatabase {
        let jobId = JobIdentifier()

        self.app.queues.add(FailingJob())
        self.app.get("test") { req in
            try await req.queue.dispatch(FailingJob.self, ["foo": "bar"], id: jobId)
            return HTTPStatus.ok
        }
        try await self.app.testable().test(.GET, "test") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        await XCTAssertThrowsErrorAsync(try await self.app.queues.queue.worker.run().get()) {
            XCTAssert($0 is FailingJob.Failure)
        }
        await XCTAssertNotNilAsync(
            try await (self.app.db(self.dbid) as! any SQLDatabase).select()
                .columns("*")
                .from(JobModel.schema)
                .where("id", .equal, jobId)
                .first()
        )
    } }

    func testDelayedJobIsRemovedFromProcessingQueue() async throws { try await self.withEachDatabase {
        let jobId = JobIdentifier()

        self.app.queues.add(DelayedJob())
        self.app.get("delay-job") { req in
            try await req.queue.dispatch(DelayedJob.self, .init(name: "vapor"), delayUntil: .init(timeIntervalSinceNow: 3600.0), id: jobId)
            return HTTPStatus.ok
        }
        try await self.app.testable().test(.GET, "delay-job") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        
        await XCTAssertEqualAsync(
            try await (self.app.db(self.dbid) as! any SQLDatabase).select()
                .columns("*")
                .from(JobModel.schema)
                .where("id", .equal, jobId)
                .first(decoding: JobModel.self, keyDecodingStrategy: .convertFromSnakeCase)?.state,
            .pending
        )
    } }

    func testCoverageForFailingQueue() async throws {
        self.app = try await Application.make(.testing)
        let queue = FailingQueue(
            failure: QueuesFluentError.unsupportedDatabase,
            context: .init(queueName: .default, configuration: .init(), application: self.app, logger: self.app.logger, on: self.app.eventLoopGroup.any())
        )
        await XCTAssertThrowsErrorAsync(try await queue.get(.init()))
        await XCTAssertThrowsErrorAsync(try await queue.set(.init(), to: JobData(payload: [], maxRetryCount: 0, jobName: "", delayUntil: nil, queuedAt: .init())))
        await XCTAssertThrowsErrorAsync(try await queue.clear(.init()))
        await XCTAssertThrowsErrorAsync(try await queue.push(.init()))
        await XCTAssertThrowsErrorAsync(try await queue.pop())
        try await self.app.asyncShutdown()
        self.app = nil
    }

    func testSQLKitUtilities() async throws { try await self.withEachDatabase {
        func serialized(_ expr: some SQLExpression) -> String {
            var serializer = SQLSerializer(database: self.app.db(self.dbid) as! any SQLDatabase)
            expr.serialize(to: &serializer)
            return serializer.sql
        }
        XCTAssertEqual(serialized(.group(.identifier("a"))), "(\(serialized(.identifier("a"))))")
        XCTAssertEqual(serialized(.column("a", table: "a")), "\(serialized(.identifier("a"))).\(serialized(.identifier("a")))")
        XCTAssertEqual(serialized(.column("a", table: .identifier("a"))), "\(serialized(.identifier("a"))).\(serialized(.identifier("a")))")
        XCTAssertEqual(serialized(.column(.identifier("a"), table: "a")), "\(serialized(.identifier("a"))).\(serialized(.identifier("a")))")
        XCTAssertEqual(serialized(.column(.identifier("a"), table: .identifier("a"))), "\(serialized(.identifier("a"))).\(serialized(.identifier("a")))")
        XCTAssertEqual(serialized(.literal(String?("a"))), "\(serialized(.literal("a")))")
        XCTAssertEqual(serialized(.literal(String?.none)), "NULL")
        XCTAssertEqual(serialized(.literal(1)), "1")
        XCTAssertEqual(serialized(.literal(Int?(1))), "1")
        XCTAssertEqual(serialized(.literal(Int?.none)), "NULL")
        XCTAssertEqual(serialized(.literal(1.0)), "1.0")
        XCTAssertEqual(serialized(.literal(Double?(1.0))), "1.0")
        XCTAssertEqual(serialized(.literal(Double?.none)), "NULL")
        XCTAssertEqual(serialized(.literal(true)), "\(serialized(SQLLiteral.boolean(true)))")
        XCTAssertEqual(serialized(.literal(Bool?(true))), "\(serialized(SQLLiteral.boolean(true)))")
        XCTAssertEqual(serialized(.literal(Bool?.none)), "NULL")
        XCTAssertEqual(serialized(.null()), "NULL")

        await XCTAssertNotNilAsync(try await (self.app.db(self.dbid) as! any SQLDatabase).transaction { $0.eventLoop.makeSucceededFuture(()) }.get())
    } }

    func testNamesCoding() throws {
        XCTAssertEqual(JobIdentifier(string: "a"), try JSONDecoder().decode(JobIdentifier.self, from: Data(#""a""#.utf8)))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(JobIdentifier(string: "a")), as: UTF8.self), #""a""#)
        XCTAssertEqual(QueueName(string: "a").string, try JSONDecoder().decode(QueueName.self, from: Data(#""a""#.utf8)).string)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(QueueName(string: "a")), as: UTF8.self), #""a""#)
    }

    override class func setUp() {
        XCTAssert(isLoggingConfigured)
    }
}

actor Email: AsyncJob {
    struct Message: Codable, Equatable {
        let to: String
    }
    
    var sent: [Message] = []
    
    func dequeue(_ context: QueueContext, _ message: Message) async throws {
        self.sent.append(message)
        context.logger.info("sending email", metadata: ["message": "\(message)"])
    }
}

struct DelayedJob: AsyncJob {
    struct Message: Codable, Equatable {
        let name: String
    }
    
    func dequeue(_ context: QueueContext, _ message: Message) async throws {
        context.logger.info("Hello", metadata: ["name": "\(message.name)"])
    }
}

struct FailingJob: AsyncJob {
    struct Failure: Error {}
    
    func dequeue(_ context: QueueContext, _ message: [String: String]) async throws { throw Failure() }
    func error(_ context: QueueContext, _ error: any Error, _ payload: [String: String]) async throws { throw Failure() }
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
    ProcessInfo.processInfo.environment[name]
}

let isLoggingConfigured: Bool = {
    LoggingSystem.bootstrap(
        fragment: timestampDefaultLoggerFragment(),
        console: Terminal(),
        level: env("LOG_LEVEL").flatMap { .init(rawValue: $0) } ?? .info
    )
    return true
}()
