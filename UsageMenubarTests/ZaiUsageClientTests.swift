import XCTest
@testable import UsageMenubar

@MainActor
final class ZaiUsageClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// A client whose requests are served by `StubURLProtocol`, with a backoff short
    /// enough that the retry tests run in milliseconds rather than seconds.
    private func makeStubbedClient(retryBaseDelay: Duration = .milliseconds(1)) -> ZaiUsageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ZaiUsageClient(session: URLSession(configuration: config), retryBaseDelay: retryBaseDelay)
    }

    /// Enqueues quota and subscription responses matched to their URL paths, so the
    /// order of arrival doesn't matter — each endpoint gets its own response.
    private func enqueueQuotaAndSubscription(
        quotaStatus: Int = 200,
        quotaJSON: Data,
        subscriptionStatus: Int = 200,
        subscriptionJSON: Data
    ) {
        StubURLProtocol.enqueue(.status(quotaStatus, quotaJSON), forURLPath: "/api/monitor/usage/quota/limit")
        StubURLProtocol.enqueue(.status(subscriptionStatus, subscriptionJSON), forURLPath: "/api/biz/subscription/list")
    }

    // MARK: - Decoding

    func testDecodeQuotaResponse() throws {
        let json = """
        {"code":200,"msg":"Operation successful","success":true,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"percentage":12,"nextResetTime":1784278018952},
            {"type":"TOKENS_LIMIT","unit":6,"percentage":3,"nextResetTime":1784286332993}
        ],"level":"max"}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: json)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.code, 200)
        XCTAssertEqual(response.data?.level, "max")
        XCTAssertEqual(response.data?.limits?.count, 2)
        XCTAssertEqual(response.data?.limits?.first?.percentage, 12)
        XCTAssertEqual(response.data?.limits?.first?.unit, 3)
    }

    func testDecodeQuotaResponseWithFractionalPercentage() throws {
        let json = """
        {"code":200,"success":true,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"percentage":12.6,"nextResetTime":1784278018952}
        ],"level":"pro"}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: json)
        XCTAssertEqual(response.data?.limits?.first?.percentage, 13)
    }

    func testDecodeQuotaResponseWithMissingFields() throws {
        let json = """
        {"code":200,"success":true,"data":{"limits":[],"level":null}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: json)
        XCTAssertEqual(response.data?.limits?.count, 0)
        XCTAssertNil(response.data?.level)
    }

    func testDecodeSubscriptionResponse() throws {
        let json = """
        {"code":200,"data":[{"productName":"GLM Coding Max","status":"VALID"}],"success":true}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ZaiSubscriptionResponse.self, from: json)
        XCTAssertEqual(response.data?.first?.productName, "GLM Coding Max")
        XCTAssertEqual(response.data?.first?.status, "VALID")
    }

    func testDecodeEmptySubscriptionResponse() throws {
        let json = """
        {"code":200,"data":[],"success":true}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ZaiSubscriptionResponse.self, from: json)
        XCTAssertEqual(response.data?.count, 0)
    }

    // MARK: - Fetch

    func testFetchUsageSuccess() async throws {
        let quotaJSON = """
        {"code":200,"msg":"Operation successful","success":true,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"percentage":12,"nextResetTime":1784278018952},
            {"type":"TOKENS_LIMIT","unit":6,"percentage":3,"nextResetTime":1784286332993}
        ],"level":"max"}}
        """.data(using: .utf8)!
        let subscriptionJSON = """
        {"code":200,"data":[{"productName":"GLM Coding Max","status":"VALID"}],"success":true}
        """.data(using: .utf8)!

        enqueueQuotaAndSubscription(quotaJSON: quotaJSON, subscriptionJSON: subscriptionJSON)

        let client = makeStubbedClient()
        let report = try await client.fetchUsage(apiKey: "test-key")

        XCTAssertEqual(report.fiveHourPercent, 12)
        XCTAssertEqual(report.weeklyPercent, 3)
        XCTAssertNotNil(report.fiveHourResetsAt)
        XCTAssertNotNil(report.weeklyResetsAt)
    }

    func testFetchUsageNoKey() async {
        let client = makeStubbedClient()
        do {
            _ = try await client.fetchUsage(apiKey: "")
            XCTFail("Expected noAPIKey error")
        } catch ZaiUsageError.noAPIKey {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testFetchUsageInvalidKey() async {
        let errorJSON = """
        {"code":401,"msg":"token expired or incorrect","success":false}
        """.data(using: .utf8)!
        StubURLProtocol.enqueue(.status(401, errorJSON), forURLPath: "/api/monitor/usage/quota/limit")
        StubURLProtocol.enqueue(.status(401, errorJSON), forURLPath: "/api/biz/subscription/list")

        let client = makeStubbedClient()
        do {
            _ = try await client.fetchUsage(apiKey: "bad-key")
            XCTFail("Expected invalidAPIKey error")
        } catch ZaiUsageError.invalidAPIKey {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Retry

    func testRetriesOnServerErrorThenSucceeds() async throws {
        let quotaJSON = """
        {"code":200,"success":true,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"percentage":12}
        ],"level":"max"}}
        """.data(using: .utf8)!
        let subscriptionJSON = """
        {"code":200,"data":[],"success":true}
        """.data(using: .utf8)!

        // Subscription succeeds on first try. Quota fails with 500, then succeeds.
        StubURLProtocol.enqueue(.status(200, subscriptionJSON), forURLPath: "/api/biz/subscription/list")
        StubURLProtocol.enqueue(.status(500, Data()), forURLPath: "/api/monitor/usage/quota/limit")
        StubURLProtocol.enqueue(.status(200, quotaJSON), forURLPath: "/api/monitor/usage/quota/limit")

        let client = makeStubbedClient()
        let report = try await client.fetchUsage(apiKey: "test-key")
        XCTAssertEqual(report.fiveHourPercent, 12)
    }

    func testRetriesOnRateLimitThenSucceeds() async throws {
        let quotaJSON = """
        {"code":200,"success":true,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"percentage":12}
        ],"level":"max"}}
        """.data(using: .utf8)!
        let subscriptionJSON = """
        {"code":200,"data":[],"success":true}
        """.data(using: .utf8)!

        StubURLProtocol.enqueue(.status(200, subscriptionJSON), forURLPath: "/api/biz/subscription/list")
        StubURLProtocol.enqueue(.status(429, Data()), forURLPath: "/api/monitor/usage/quota/limit")
        StubURLProtocol.enqueue(.status(200, quotaJSON), forURLPath: "/api/monitor/usage/quota/limit")

        let client = makeStubbedClient()
        let report = try await client.fetchUsage(apiKey: "test-key")
        XCTAssertEqual(report.fiveHourPercent, 12)
    }

    func testDoesNotRetryOn401() async {
        let errorJSON = """
        {"code":401,"msg":"token expired or incorrect","success":false}
        """.data(using: .utf8)!
        StubURLProtocol.enqueue(.status(401, errorJSON), forURLPath: "/api/monitor/usage/quota/limit")
        StubURLProtocol.enqueue(.status(401, errorJSON), forURLPath: "/api/biz/subscription/list")

        let client = makeStubbedClient()
        do {
            _ = try await client.fetchUsage(apiKey: "bad-key")
            XCTFail("Expected invalidAPIKey error")
        } catch ZaiUsageError.invalidAPIKey {
            // Expected — should not retry
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - ZaiUsageReport

    func testEmptyReportIsEmpty() {
        let report = ZaiUsageReport(
            fiveHourPercent: nil,
            weeklyPercent: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            planLevel: nil
        )
        XCTAssertTrue(report.isEmpty)
    }

    func testNonEmptyReportIsNotEmpty() {
        let report = ZaiUsageReport(
            fiveHourPercent: 12,
            weeklyPercent: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            planLevel: nil
        )
        XCTAssertFalse(report.isEmpty)
    }

    // MARK: - Protocol conformance

    func testZaiUsageClientConformsToProtocol() {
        let checker: ZaiUsageChecking = ZaiUsageClient()
        // If this compiles, ZaiUsageClient conforms to ZaiUsageChecking.
        XCTAssertNotNil(checker)
    }
}