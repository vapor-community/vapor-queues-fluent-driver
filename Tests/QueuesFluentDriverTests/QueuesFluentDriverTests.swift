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

extension DatabaseID {
    static var mysql2: Self { .init(string: "mysql2") }
}

final class QueuesFluentDriverTests: XCTestCase {
    var app: Application!
    var dbid: DatabaseID!

    private func useDBs(_ app: Application) throws {
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
        if env("MYSQL_B") != nil {
            app.databases.use(DatabaseConfigurationFactory.mysql(configuration: .init(
                hostname: env("MYSQL_HOST_B")     ?? env("DATABASE_HOST")     ?? "localhost",
                port:     (env("MYSQL_PORT_B")    ?? env("DATABASE_PORT")).flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
                username: env("MYSQL_USERNAME_B") ?? env("DATABASE_USERNAME") ?? "test_username",
                password: env("MYSQL_PASSWORD_B") ?? env("DATABASE_PASSWORD") ?? "test_password",
                database: env("MYSQL_NAME_B")     ?? env("DATABASE_NAME")     ?? "test_database",
                tlsConfiguration: config
            )), as: .mysql2)
        }
        #endif
    }

    private func withEachDatabase(preserveJobs: Bool = false, tableName: String = "_jobs_meta", _ closure: () async throws -> Void) async throws {
        func run(_ dbid: DatabaseID, defaultSpace: String? = nil) async throws {
            self.dbid = dbid
            self.app = try await Application.make(.testing)
            self.app.logger[metadataKey: "test-dbid"] = "\(dbid.string)"

            try self.useDBs(self.app)
            self.app.migrations.add(JobModelMigration(jobsTableName: tableName, jobsTableSpace: defaultSpace), to: self.dbid)
            self.app.queues.use(.fluent(self.dbid, preservesCompletedJobs: preserveJobs, jobsTableName: tableName, jobsTableSpace: defaultSpace))

            try await self.app.autoMigrate()

            do { try await closure() }
            catch {
                try? await self.app.autoRevert()
                try? await self.app.asyncShutdown()
                self.app = nil
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
        try await run(.psql, defaultSpace: "public")
        #endif

        #if canImport(FluentMySQLDriver)
        try await run(.mysql, defaultSpace: env("MYSQL_NAME") ?? env("DATABASE_NAME") ?? "test_database")
        if env("MYSQL_B") != nil {
            try await run(.mysql2, defaultSpace: env("MYSQL_NAME_B") ?? env("DATABASE_NAME") ?? "test_database")
        }
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
        let jobID = JobIdentifier()

        self.app.queues.add(FailingJob())
        self.app.get("test") { req in
            try await req.queue.dispatch(FailingJob.self, ["foo": "bar"], id: jobID)
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
                .from("_jobs_meta")
                .where("id", .equal, jobID)
                .first()
        )
    } }

    func testFailedJobRetry() async throws { try await self.withEachDatabase {
        let jobID = JobIdentifier()
        
        let failingJob = FailingJob()
        
        self.app.queues.add(failingJob)
        self.app.get("test") { req in
            try await req.queue.dispatch(FailingJob.self, [:], maxRetryCount: 5, id: jobID)
            return HTTPStatus.ok
        }
        try await self.app.testable().test(.GET, "test") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        
        try? await self.app.queues.queue.worker.run().get()
        await XCTAssertEqualAsync(await failingJob.runCount, 6)
    } }

    func testDelayedJobIsRemovedFromProcessingQueue() async throws { try await self.withEachDatabase {
        let jobID = JobIdentifier()

        self.app.queues.add(DelayedJob())
        self.app.get("delay-job") { req in
            try await req.queue.dispatch(DelayedJob.self, .init(name: "vapor"), delayUntil: .init(timeIntervalSinceNow: 3600.0), id: jobID)
            return HTTPStatus.ok
        }
        try await self.app.testable().test(.GET, "delay-job") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        
        await XCTAssertEqualAsync(
            try await (self.app.db(self.dbid) as! any SQLDatabase).select()
                .columns("*")
                .from("_jobs_meta")
                .where("id", .equal, jobID)
                .first(decoding: JobModel.self, keyDecodingStrategy: .convertFromSnakeCase)?.state,
            .pending
        )
    } }

    func testCustomTableNameAndJobDeletionByDefault() async throws { try await self.withEachDatabase(tableName: "_jobs_custom") {
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
        await XCTAssertEqualAsync(
            try await (self.app.db(self.dbid) as! any SQLDatabase).select()
                .column(SQLFunction("count", args: SQLIdentifier("id")), as: "count")
                .from("_jobs_custom")
                .first(decodingColumn: "count", as: Int.self),
            0
        )
    } }

    func testJobPreservation() async throws { try await self.withEachDatabase(preserveJobs: true) {
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
        await XCTAssertEqualAsync(
            try await (self.app.db(self.dbid) as! any SQLDatabase).select()
                .column(SQLFunction("count", args: SQLIdentifier("id")), as: "count")
                .from("_jobs_meta")
                .first(decodingColumn: "count", as: Int.self),
            1
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

    func testCoverageForJobModel() {
        let date = Date()
        let model = JobModel(id: .init(string: "test"), queue: .init(string: "test"), jobData: .init(payload: [], maxRetryCount: 0, jobName: "", delayUntil: nil, queuedAt: date))

        XCTAssertEqual(model.id, "test")
        XCTAssertEqual(model.queueName, "test")
        XCTAssertEqual(model.jobName, "")
        XCTAssertEqual(model.queuedAt, date)
        XCTAssertNil(model.delayUntil)
        XCTAssertEqual(model.state, .pending)
        XCTAssertEqual(model.maxRetryCount, 0)
        XCTAssertEqual(model.attempts, 0)
        XCTAssertEqual(model.payload, Data())
        XCTAssertNotNil(model.updatedAt)
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
        XCTAssertEqual(serialized(SQLLockingClauseWithSkipLocked.shareSkippingLocked), serialized(SQLLockingClause.share) != "" ? "\(serialized(SQLLockingClause.share)) SKIP LOCKED" : "")

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

actor FailingJob: AsyncJob {
    struct Failure: Error {}
    
    var runCount = 0
    
    func dequeue(_ context: QueueContext, _ message: [String: String]) async throws {
        runCount += 1
        throw Failure()
    }
    
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

func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTAssertNoThrow(try { throw error }(), message(), file: file, line: line)
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
