import XCTest
import Foundation
@testable import UsageMenubar

/// The instant every test pretends it is. Injected into the client, so token expiry is
/// a decision the test makes rather than a race against the wall clock.
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

final class ClaudeUsageClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A client whose requests are served by `StubURLProtocol` and whose credentials
    /// come from memory, so no test here touches the real Keychain, the real
    /// `~/.claude/.credentials.json`, or the network. The backoff is short enough that
    /// the retry tests run in milliseconds rather than seconds.
    private func makeClient(
        store: ClaudeCredentialStoring,
        retryBaseDelay: Duration = .milliseconds(1)
    ) -> ClaudeUsageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudeUsageClient(
            session: URLSession(configuration: config),
            store: store,
            retryBaseDelay: retryBaseDelay,
            now: { fixedNow }
        )
    }

    private func credentials(
        accessToken: String = "access-1",
        refreshToken: String = "refresh-1",
        expiresAt: Date = fixedNow.addingTimeInterval(3600),
        subscriptionType: String? = "max"
    ) -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            claudeAiOauth: .init(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Int64(expiresAt.timeIntervalSince1970 * 1000),
                scopes: ["user:inference"],
                subscriptionType: subscriptionType,
                rateLimitTier: nil
            )
        )
    }

    /// Credentials whose access token is already spent, so a fetch has to refresh first.
    private func expiredCredentials() -> ClaudeOAuthCredentials {
        credentials(expiresAt: fixedNow.addingTimeInterval(-1))
    }

    private func usageJSON(fiveHour: Int = 68, sevenDay: Int = 41) -> Data {
        Data("""
        {
          "five_hour": {"utilization": \(fiveHour), "resets_at": "2023-11-14T23:53:20.000Z"},
          "seven_day": {"utilization": \(sevenDay), "resets_at": "2023-11-20T23:53:20.000Z"}
        }
        """.utf8)
    }

    private func tokenJSON(
        accessToken: String = "access-2",
        refreshToken: String? = "refresh-2",
        expiresIn: Int? = 3600
    ) -> Data {
        var fields = [#""access_token": "\#(accessToken)""#]
        if let refreshToken { fields.append(#""refresh_token": "\#(refreshToken)""#) }
        if let expiresIn { fields.append(#""expires_in": \#(expiresIn)"#) }
        return Data("{\(fields.joined(separator: ", "))}".utf8)
    }

    private func requests(to url: URL) -> [URLRequest] {
        StubURLProtocol.recordedRequests.filter { $0.url == url }
    }

    // MARK: - Usage decoding

    func testDecodesUsagePayload() throws {
        let json = Data("""
        {
          "five_hour": {"utilization": 68.4, "resets_at": "2026-07-11T20:00:00.000Z"},
          "seven_day": {"utilization": 41, "resets_at": "2026-07-15T20:00:00.000Z"},
          "seven_day_opus": {"utilization": 12, "resets_at": null},
          "limits": [
            {"percent": 41, "is_active": false, "resets_at": "2026-07-15T20:00:00.000Z"},
            {"percent": 68, "is_active": true, "resets_at": "2026-07-11T20:00:00.000Z"}
          ]
        }
        """.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.fiveHour?.utilization, 68.4)
        XCTAssertEqual(usage.sevenDay?.utilization, 41)
        XCTAssertEqual(usage.sevenDayOpus?.utilization, 12)
        XCTAssertNil(usage.sevenDayOpus?.resetsAt)
        XCTAssertEqual(usage.limits?.count, 2)
        XCTAssertFalse(usage.isEmpty)
    }

    func testDecodesEmptyPayload() throws {
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data("{}".utf8))

        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.limits)
        XCTAssertTrue(usage.isEmpty, "An account with no usage has nothing worth a section")
    }

    func testIgnoresWindowsItDoesNotModel() throws {
        // Anthropic adds and retires windows without notice; an unknown one must not
        // take the rest of the payload down with it.
        let json = Data("""
        {
          "five_hour": {"utilization": 5},
          "tangelo": {"utilization": 99},
          "iguana_necktie": {"utilization": 99},
          "spend": {"percent": 3, "enabled": true}
        }
        """.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.fiveHour?.utilization, 5)
        XCTAssertFalse(usage.isEmpty)
    }

    func testMissingUtilizationDefaultsToZero() throws {
        let json = Data(#"{"five_hour": {"resets_at": "2026-07-11T20:00:00.000Z"}}"#.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.fiveHour?.utilization, 0)
    }

    func testFractionalPercentIsRounded() throws {
        // The field is documented as an integer, but decoding it as one would throw on
        // a fractional value and lose the whole payload.
        let json = Data(#"{"limits": [{"percent": 68.6, "is_active": true}]}"#.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.activeLimit?.percent, 69)
    }

    func testActiveLimitIsTheOneTheServerFlags() throws {
        let json = Data("""
        {"limits": [
          {"percent": 41, "is_active": false},
          {"percent": 68, "is_active": true}
        ]}
        """.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.activeLimit?.percent, 68)
    }

    func testActiveLimitIsNilWhenNoneIsFlagged() throws {
        let json = Data(#"{"limits": [{"percent": 41}, {"percent": 12}]}"#.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertNil(usage.activeLimit)
    }

    // MARK: - Reset countdown

    func testResetsInFormatsHoursAndMinutes() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(3 * 3600 + 20 * 60)))

        XCTAssertEqual(window.resetsIn(from: fixedNow), "3h 20m")
    }

    func testResetsInFormatsDaysAndHours() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(28 * 3600)))

        XCTAssertEqual(window.resetsIn(from: fixedNow), "1d 4h")
    }

    func testResetsInFormatsMinutesAlone() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(12 * 60)))

        XCTAssertEqual(window.resetsIn(from: fixedNow), "12m")
    }

    func testResetsInIsNilOnceTheWindowHasPassed() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(-60)))

        XCTAssertNil(window.resetsIn(from: fixedNow))
    }

    func testResetsInIsNilWithoutATimestamp() {
        XCTAssertNil(UsageWindow(utilization: 0).resetsIn(from: fixedNow))
    }

    func testResetsAtParsesTimestampsWithoutFractionalSeconds() {
        // Claude's timestamps normally carry fractional seconds; this spelling has to
        // parse too, rather than silently costing us the countdown.
        let window = UsageWindow(utilization: 50, resetsAt: "2026-07-11T20:00:00Z")

        XCTAssertEqual(window.resetsAtDate?.timeIntervalSince1970, 1_783_800_000)
    }

    func testResetsAtIsNilForAnUnparseableTimestamp() {
        XCTAssertNil(UsageWindow(utilization: 50, resetsAt: "not a date").resetsAtDate)
    }

    func testLimitAlsoCountsDown() {
        let limit = Limit(percent: 68, resetsAt: iso(fixedNow.addingTimeInterval(90 * 60)), isActive: true)

        XCTAssertEqual(limit.resetsIn(from: fixedNow), "1h 30m")
    }

    // MARK: - Fetching

    func testFetchSendsTheOAuthHeaders() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(200, usageJSON()))

        let report = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(report.usage.fiveHour?.utilization, 68)
        XCTAssertEqual(report.subscriptionType, "max")

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url, ClaudeUsageClient.usageEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testMissingCredentialsThrowWithoutTouchingTheNetwork() async {
        let store = FakeClaudeCredentialStore(credentials: nil)

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected noCredentials error")
        } catch ClaudeUsageError.noCredentials {
            // expected — the caller reads this as "Claude Code isn't set up here"
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testValidTokenIsUsedWithoutRefreshing() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(200, usageJSON()))

        _ = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertTrue(requests(to: ClaudeUsageClient.tokenEndpoint).isEmpty)
        XCTAssertTrue(store.savedCredentials.isEmpty, "Nothing was rotated, so nothing to write back")
    }

    // MARK: - Token refresh

    func testExpiredTokenIsRefreshedBeforeTheUsageRequest() async throws {
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(
            .status(200, tokenJSON(accessToken: "access-2")),
            .status(200, usageJSON())
        )

        let report = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(report.usage.fiveHour?.utilization, 68)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)

        let recorded = StubURLProtocol.recordedRequests
        XCTAssertEqual(recorded[0].url, ClaudeUsageClient.tokenEndpoint)
        XCTAssertEqual(recorded[0].httpMethod, "POST")
        XCTAssertEqual(recorded[1].url, ClaudeUsageClient.usageEndpoint)
        XCTAssertEqual(
            recorded[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer access-2",
            "The usage request has to carry the refreshed token, not the spent one"
        )
    }

    func testRefreshRotatesAndPersistsTheCredentials() async throws {
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(
            .status(200, tokenJSON(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 3600)),
            .status(200, usageJSON())
        )

        _ = try await makeClient(store: store).fetchUsage()

        let saved = try XCTUnwrap(store.savedCredentials.last)
        let token = saved.credentials.claudeAiOauth
        XCTAssertEqual(token.accessToken, "access-2")
        XCTAssertEqual(
            token.refreshToken,
            "refresh-2",
            "The server rotated the refresh token; failing to store it would sign Claude Code out"
        )
        XCTAssertEqual(token.expiresAt, Int64((fixedNow.timeIntervalSince1970 + 3600) * 1000))
        XCTAssertEqual(saved.source, .keychain(account: "tester"), "Written back where it was read from")
    }

    func testRefreshKeepsTheOldRefreshTokenWhenTheServerDoesNotRotateIt() async throws {
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(
            .status(200, tokenJSON(accessToken: "access-2", refreshToken: nil)),
            .status(200, usageJSON())
        )

        _ = try await makeClient(store: store).fetchUsage()

        let saved = try XCTUnwrap(store.savedCredentials.last)
        XCTAssertEqual(saved.credentials.claudeAiOauth.refreshToken, "refresh-1")
    }

    func testRefreshWithoutExpiresInAssumesEightHours() async throws {
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(
            .status(200, tokenJSON(accessToken: "access-2", expiresIn: nil)),
            .status(200, usageJSON())
        )

        _ = try await makeClient(store: store).fetchUsage()

        let saved = try XCTUnwrap(store.savedCredentials.last)
        XCTAssertEqual(
            saved.credentials.claudeAiOauth.expiresAt,
            Int64((fixedNow.timeIntervalSince1970 + 8 * 3600) * 1000)
        )
    }

    func testRefreshSendsTheGrant() async throws {
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(.status(200, tokenJSON()), .status(200, usageJSON()))

        _ = try await makeClient(store: store).fetchUsage()

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first ?? nil)
        let grant = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(grant["grant_type"], "refresh_token")
        XCTAssertEqual(grant["refresh_token"], "refresh-1")
        XCTAssertEqual(grant["client_id"], ClaudeUsageClient.clientID)
        XCTAssertEqual(grant["scope"], ClaudeUsageClient.scope)
    }

    func testRefreshFallsBackToFormEncoding() async throws {
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(
            .status(400, Data()),                        // the JSON body is rejected
            .status(200, tokenJSON(accessToken: "access-2")),
            .status(200, usageJSON())
        )

        _ = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(StubURLProtocol.requestCount, 3)
        let contentTypes = StubURLProtocol.recordedRequests.prefix(2).map {
            $0.value(forHTTPHeaderField: "Content-Type")
        }
        XCTAssertEqual(contentTypes, ["application/json", "application/x-www-form-urlencoded"])

        let form = try XCTUnwrap(StubURLProtocol.recordedBodies[1].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(form.contains("grant_type=refresh_token"), "Got: \(form)")
        XCTAssertTrue(form.contains("refresh_token=refresh-1"), "Got: \(form)")
        XCTAssertTrue(
            form.contains("user%3Ainference"),
            "The colons in the scope have to be percent-encoded, not sent raw. Got: \(form)"
        )
    }

    func testRefreshFailureThrowsTokenRefreshFailed() async {
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(.status(400, Data()))  // repeats, so both encodings fail

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected tokenRefreshFailed error")
        } catch ClaudeUsageError.tokenRefreshFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Both encodings tried, and no usage request made with a token we never got.
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertTrue(requests(to: ClaudeUsageClient.usageEndpoint).isEmpty)
    }

    func testConcurrentFetchesShareASingleRefresh() async throws {
        // Two refreshes at once would each spend the refresh token, and whichever
        // finished second would be left holding one the server had already retired.
        let store = FakeClaudeCredentialStore(credentials: expiredCredentials())
        StubURLProtocol.enqueue(.status(200, tokenJSON()), .status(200, usageJSON()))

        let client = makeClient(store: store)
        async let first = client.fetchUsage()
        async let second = client.fetchUsage()
        _ = try await (first, second)

        XCTAssertEqual(requests(to: ClaudeUsageClient.tokenEndpoint).count, 1)
        XCTAssertEqual(requests(to: ClaudeUsageClient.usageEndpoint).count, 2)
        XCTAssertEqual(store.savedCredentials.count, 1)
    }

    // MARK: - Rejected tokens

    func testRejectedTokenIsRefreshedOnceThenRetried() async throws {
        // A token can be revoked server-side well before its stated expiry.
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(
            .status(401, Data()),
            .status(200, tokenJSON(accessToken: "access-2")),
            .status(200, usageJSON())
        )

        let report = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(report.usage.fiveHour?.utilization, 68)
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
        XCTAssertEqual(
            StubURLProtocol.recordedRequests[2].value(forHTTPHeaderField: "Authorization"),
            "Bearer access-2"
        )
    }

    func testRepeatedRejectionSurfacesInvalidCredentials() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(
            .status(401, Data()),
            .status(200, tokenJSON(accessToken: "access-2")),
            .status(401, Data())
        )

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected invalidCredentials error")
        } catch ClaudeUsageError.invalidCredentials {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // One refresh, and no attempt at a second: it plainly isn't the token.
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
        XCTAssertEqual(requests(to: ClaudeUsageClient.tokenEndpoint).count, 1)
    }

    func testFailedRefreshAfterRejectionSurfacesTheRejection() async {
        // "Couldn't refresh" says less than "the server rejected your token", and both
        // point at the same fix, so the rejection is the more useful of the two.
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(401, Data()), .status(403, Data()))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected invalidCredentials error")
        } catch ClaudeUsageError.invalidCredentials {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testForbiddenIsTreatedAsARejectedToken() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(403, Data()))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected invalidCredentials error")
        } catch ClaudeUsageError.invalidCredentials {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Retries

    func testRetriesOnServerErrorThenSucceeds() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(
            .status(500, Data()),
            .status(503, Data()),
            .status(200, usageJSON())
        )

        let report = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(report.usage.fiveHour?.utilization, 68)
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testRetriesOnRateLimitThenSucceeds() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(429, Data()), .status(200, usageJSON()))

        _ = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testRetriesOnNetworkErrorThenSucceeds() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.failure(URLError(.timedOut)), .status(200, usageJSON()))

        _ = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testGivesUpAfterTwoRetries() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(500, Data()))  // repeats

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected requestFailed error")
        } catch ClaudeUsageError.requestFailed(let message) {
            XCTAssertEqual(message, "HTTP 500")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Initial attempt + 2 retries.
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testDoesNotRetryOnClientError() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(404, Data()))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected requestFailed error")
        } catch ClaudeUsageError.requestFailed(let message) {
            XCTAssertEqual(message, "HTTP 404")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testDoesNotRetryOnDecodingFailure() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(200, Data("not json".utf8)))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected decodingFailed error")
        } catch ClaudeUsageError.decodingFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // MARK: - Errors

    func testErrorsAreEquatable() {
        XCTAssertEqual(ClaudeUsageError.noCredentials, .noCredentials)
        XCTAssertNotEqual(ClaudeUsageError.noCredentials, .invalidCredentials)
        XCTAssertEqual(ClaudeUsageError.requestFailed("HTTP 500"), .requestFailed("HTTP 500"))
    }

    func testClaudeUsageClientConformsToProtocol() {
        let checker: ClaudeUsageChecking = ClaudeUsageClient()
        // If this compiles, ClaudeUsageClient conforms to ClaudeUsageChecking.
        XCTAssertNotNil(checker)
    }

    // MARK: - Helpers

    /// An ISO 8601 timestamp with fractional seconds, as Claude's API spells them.
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Credential store

/// These drive `ClaudeCodeCredentialStore` against a throwaway file and a Keychain
/// service that cannot exist, so `security` always misses and the file fallback is what
/// gets exercised. Nothing here can read — let alone write — the real Claude Code
/// credentials, which is the whole point: a test that clobbered them would sign the
/// user out of their own CLI.
final class ClaudeCodeCredentialStoreTests: XCTestCase {

    private var directory: URL!

    /// A credentials blob carrying two fields we deliberately don't model.
    private let credentialsJSON = """
    {
      "claudeAiOauth": {
        "accessToken": "access-1",
        "refreshToken": "refresh-1",
        "expiresAt": 4000000000000,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max",
        "somethingWeDoNotModel": "keep me"
      },
      "anotherTopLevelKey": "keep me too"
    }
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeStore(file: URL) -> ClaudeCodeCredentialStore {
        ClaudeCodeCredentialStore(
            keychainService: "com.example.tests.absent-\(UUID().uuidString)",
            credentialsFile: file
        )
    }

    private func writeCredentialsFile() throws -> URL {
        let file = directory.appendingPathComponent(".credentials.json")
        try Data(credentialsJSON.utf8).write(to: file)
        return file
    }

    func testReadsCredentialsFromTheFileWhenTheKeychainHasNothing() throws {
        let file = try writeCredentialsFile()

        let stored = try XCTUnwrap(makeStore(file: file).load())

        XCTAssertEqual(stored.credentials.claudeAiOauth.accessToken, "access-1")
        XCTAssertEqual(stored.credentials.claudeAiOauth.refreshToken, "refresh-1")
        XCTAssertEqual(stored.credentials.claudeAiOauth.subscriptionType, "max")
        XCTAssertEqual(stored.source, .file(file))
    }

    func testReturnsNilWhenThereIsNeitherAKeychainItemNorAFile() {
        let missing = directory.appendingPathComponent("nothing-here.json")

        XCTAssertNil(makeStore(file: missing).load())
    }

    func testReturnsNilForACorruptedFile() throws {
        let file = directory.appendingPathComponent(".credentials.json")
        try Data("{ not json".utf8).write(to: file)

        XCTAssertNil(makeStore(file: file).load())
    }

    func testWriteBackRotatesTheTokensAndKeepsEverythingElse() throws {
        let file = try writeCredentialsFile()
        let store = makeStore(file: file)

        var stored = try XCTUnwrap(store.load())
        stored.credentials.claudeAiOauth.accessToken = "access-2"
        stored.credentials.claudeAiOauth.refreshToken = "refresh-2"
        stored.credentials.claudeAiOauth.expiresAt = 4_100_000_000_000
        store.save(stored)

        let written = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        let oauth = try XCTUnwrap(written["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "access-2")
        XCTAssertEqual(oauth["refreshToken"] as? String, "refresh-2")
        XCTAssertEqual((oauth["expiresAt"] as? NSNumber)?.int64Value, 4_100_000_000_000)

        // This is the file the user's CLI signs in with. Round-tripping it through our
        // own type would drop the fields we don't model, so the write patches the raw
        // JSON instead — and these two have to survive it.
        XCTAssertEqual(oauth["somethingWeDoNotModel"] as? String, "keep me")
        XCTAssertEqual(written["anotherTopLevelKey"] as? String, "keep me too")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
    }

    func testWriteBackLeavesTheFileReadableOnlyByItsOwner() throws {
        let file = try writeCredentialsFile()
        let store = makeStore(file: file)

        let stored = try XCTUnwrap(store.load())
        store.save(stored)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.int16Value,
            0o600,
            "An atomic write replaces the file, so the mode has to be reapplied"
        )
    }
}

// MARK: - Fake credential store

/// An in-memory `ClaudeCredentialStoring`. Never goes near the Keychain or the disk.
final class FakeClaudeCredentialStore: ClaudeCredentialStoring {
    private let lock = NSLock()
    private var current: StoredClaudeCredentials?
    private var writes: [StoredClaudeCredentials] = []

    init(
        credentials: ClaudeOAuthCredentials?,
        source: ClaudeCredentialSource = .keychain(account: "tester")
    ) {
        current = credentials.map { StoredClaudeCredentials(credentials: $0, source: source) }
    }

    /// Every write-back the client has made, oldest first.
    var savedCredentials: [StoredClaudeCredentials] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func load() -> StoredClaudeCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func save(_ stored: StoredClaudeCredentials) {
        lock.lock()
        defer { lock.unlock() }
        current = stored
        writes.append(stored)
    }
}
