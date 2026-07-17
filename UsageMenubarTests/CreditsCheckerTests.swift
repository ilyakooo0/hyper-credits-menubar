import XCTest
import Foundation
import Security
@testable import UsageMenubar

final class CreditsCheckerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// A checker whose requests are served by `StubURLProtocol`, with a backoff short
    /// enough that the retry tests run in milliseconds rather than seconds.
    private func makeStubbedChecker(retryBaseDelay: Duration = .milliseconds(1)) -> CreditsChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return CreditsChecker(session: URLSession(configuration: config), retryBaseDelay: retryBaseDelay)
    }

    // MARK: - BalanceResponse Decoding

    func testDecodeValidBalance() throws {
        let json = #"{"balance": 42}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 42)
    }

    func testDecodeZeroBalance() throws {
        let json = #"{"balance": 0}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 0)
    }

    func testDecodeLargeBalance() throws {
        let json = #"{"balance": 999999}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 999999)
    }

    func testDecodeMissingBalanceThrows() {
        let json = #"{"foo": "bar"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(BalanceResponse.self, from: json))
    }

    func testDecodeNegativeBalance() throws {
        // The API could theoretically return a negative balance
        let json = #"{"balance": -5}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, -5)
    }

    // MARK: - Fractional balance decoding

    func testDecodeFractionalBalanceRoundsUp() throws {
        let json = #"{"balance": 42.5}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 43)
    }

    func testDecodeFractionalBalanceRoundsDown() throws {
        let json = #"{"balance": 42.4}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 42)
    }

    func testDecodeNegativeFractionalBalanceRoundsAwayFromZero() throws {
        let json = #"{"balance": -2.5}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, -3)
    }

    func testDecodeFractionalZeroBalance() throws {
        let json = #"{"balance": 0.2}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 0)
    }

    func testDecodeIntegerValuedDoubleBalance() throws {
        let json = #"{"balance": 100.0}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 100)
    }

    func testDecodeBalanceTooLargeForIntThrows() {
        // Not representable as an Int, so rounding cannot save it.
        let json = #"{"balance": 1e30}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(BalanceResponse.self, from: json))
    }

    func testDecodeStringBalanceThrows() {
        let json = #"{"balance": "42"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(BalanceResponse.self, from: json))
    }

    func testFetchBalanceRoundsFractionalResponse() async throws {
        StubURLProtocol.enqueue(.status(200, #"{"balance": 12.7}"#.data(using: .utf8)!))

        let balance = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")

        XCTAssertEqual(balance, 13)
    }

    // MARK: - Request construction

    func testRequestSendsNoCacheAndAuthorizationHeaders() async throws {
        StubURLProtocol.enqueue(.status(200, #"{"balance": 1}"#.data(using: .utf8)!))

        _ = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: - Retry behaviour

    func testRetriesOnServerErrorThenSucceeds() async throws {
        StubURLProtocol.enqueue(
            .status(500, Data()),
            .status(503, Data()),
            .status(200, #"{"balance": 7}"#.data(using: .utf8)!)
        )

        let balance = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")

        XCTAssertEqual(balance, 7)
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testRetriesOnNetworkTimeoutThenSucceeds() async throws {
        StubURLProtocol.enqueue(
            .failure(URLError(.timedOut)),
            .status(200, #"{"balance": 5}"#.data(using: .utf8)!)
        )

        let balance = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")

        XCTAssertEqual(balance, 5)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testGivesUpAfterTwoRetries() async {
        // The last enqueued outcome repeats, so every attempt sees a 500.
        StubURLProtocol.enqueue(.status(500, Data()))

        do {
            _ = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")
            XCTFail("Expected requestFailed error")
        } catch CreditsError.requestFailed(let message) {
            XCTAssertEqual(message, "HTTP 500")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Initial attempt + 2 retries.
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testGivesUpAfterTwoRetriesOnPersistentNetworkFailure() async {
        StubURLProtocol.enqueue(.failure(URLError(.networkConnectionLost)))

        do {
            _ = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")
            XCTFail("Expected requestFailed error")
        } catch CreditsError.requestFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testRetriesOnRateLimitThenSucceeds() async throws {
        StubURLProtocol.enqueue(
            .status(429, Data()),
            .status(200, #"{"balance": 3}"#.data(using: .utf8)!)
        )

        let balance = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")

        XCTAssertEqual(balance, 3)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testDoesNotRetryOnUnauthorized() async {
        StubURLProtocol.enqueue(.status(401, Data()))

        do {
            _ = try await makeStubbedChecker().fetchBalance(apiKey: "sk-bad")
            XCTFail("Expected invalidAPIKey error")
        } catch CreditsError.invalidAPIKey {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testDoesNotRetryOnClientError() async {
        StubURLProtocol.enqueue(.status(404, Data()))

        do {
            _ = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")
            XCTFail("Expected requestFailed error")
        } catch CreditsError.requestFailed(let message) {
            XCTAssertEqual(message, "HTTP 404")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testDoesNotRetryOnDecodingFailure() async {
        StubURLProtocol.enqueue(.status(200, #"{"nope": true}"#.data(using: .utf8)!))

        do {
            _ = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")
            XCTFail("Expected decodingFailed error")
        } catch CreditsError.decodingFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testSucceedsWithoutRetryOnFirstAttempt() async throws {
        StubURLProtocol.enqueue(.status(200, #"{"balance": 99}"#.data(using: .utf8)!))

        let balance = try await makeStubbedChecker().fetchBalance(apiKey: "sk-test")

        XCTAssertEqual(balance, 99)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testBackoffGrowsExponentially() async {
        StubURLProtocol.enqueue(.status(500, Data()))

        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await makeStubbedChecker(retryBaseDelay: .milliseconds(20)).fetchBalance(apiKey: "sk-test")
        let elapsed = clock.now - start

        // Two retries wait 20ms then 40ms. Only a lower bound is asserted: sleeps can
        // overshoot under load, but they never return early.
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(60))
    }

    // MARK: - CreditsChecker Errors

    func testEmptyAPIKeyThrowsNoAPIKey() async {
        let checker = CreditsChecker()
        do {
            _ = try await checker.fetchBalance(apiKey: "")
            XCTFail("Expected noAPIKey error")
        } catch CreditsError.noAPIKey {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyAPIKeyDoesNotHitTheNetwork() async {
        _ = try? await makeStubbedChecker().fetchBalance(apiKey: "")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // MARK: - CreditsError cases

    func testInvalidAPIKeyErrorDescription() {
        XCTAssertEqual(
            CreditsError.invalidAPIKey.errorDescription,
            "Invalid API key. Check your key at hyper.charm.land"
        )
    }

    func testInvalidAPIKeyIsEquatable() {
        XCTAssertEqual(CreditsError.invalidAPIKey, .invalidAPIKey)
        XCTAssertNotEqual(CreditsError.invalidAPIKey, .noAPIKey)
    }

    // MARK: - CreditsChecking protocol

    func testCreditsCheckerConformsToProtocol() {
        let checker: CreditsChecking = CreditsChecker()
        // If this compiles, CreditsChecker conforms to CreditsChecking.
        XCTAssertNotNil(checker)
    }

    // MARK: - Mock CreditsChecker for ViewModel tests

    func testMockCreditsCheckerReturnsBalance() async throws {
        let mock = MockCreditsChecker(balanceToReturn: 42)
        let result = try await mock.fetchBalance(apiKey: "sk-test")
        XCTAssertEqual(result, 42)
    }

    func testMockCreditsCheckerThrowsError() async {
        let mock = MockCreditsChecker(errorToThrow: CreditsError.invalidAPIKey)
        do {
            _ = try await mock.fetchBalance(apiKey: "sk-test")
            XCTFail("Expected invalidAPIKey error")
        } catch CreditsError.invalidAPIKey {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - KeychainStore

/// These tests drive `KeychainStore` with stubbed `SecItem*` calls rather than
/// `KeychainHelper`, which would read and write the user's real login keychain entry —
/// and `save()` deletes before adding, so a test run would destroy a real API key.
final class KeychainStoreTests: XCTestCase {

    private func makeStore(backing: FakeKeychain) -> KeychainStore {
        KeychainStore(
            service: "com.example.tests",
            account: "test-account",
            addItem: backing.add,
            copyMatching: backing.copyMatching,
            deleteItem: backing.delete
        )
    }

    func testSaveReturnsTrueOnSuccess() {
        let store = makeStore(backing: FakeKeychain())
        XCTAssertTrue(store.save("sk-test"))
    }

    func testSaveReturnsFalseWhenItemCannotBeAdded() {
        let backing = FakeKeychain()
        backing.addStatus = errSecInteractionNotAllowed  // e.g. the keychain is locked
        let store = makeStore(backing: backing)

        XCTAssertFalse(store.save("sk-test"))
        XCTAssertNil(store.load(), "A rejected save must not leave a value behind")
    }

    func testSaveReturnsFalseWhenKeychainIsUnavailable() {
        let backing = FakeKeychain()
        backing.addStatus = errSecNotAvailable
        XCTAssertFalse(makeStore(backing: backing).save("sk-test"))
    }

    func testSaveThenLoadRoundTrips() {
        let store = makeStore(backing: FakeKeychain())

        XCTAssertTrue(store.save("sk-round-trip"))
        XCTAssertEqual(store.load(), "sk-round-trip")
    }

    func testSaveOverwritesExistingKey() {
        let backing = FakeKeychain()
        let store = makeStore(backing: backing)

        XCTAssertTrue(store.save("sk-first"))
        XCTAssertTrue(store.save("sk-second"))

        XCTAssertEqual(store.load(), "sk-second")
        // The first save adds straight into an empty keychain. Only the second hits
        // errSecDuplicateItem and has to delete before re-adding.
        XCTAssertEqual(backing.deleteCallCount, 1)
    }

    func testRejectedSaveLeavesTheExistingKeyIntact() {
        // Deleting before adding would make a rejected save destroy the working key the
        // user already had, leaving them with nothing.
        let backing = FakeKeychain()
        let store = makeStore(backing: backing)

        XCTAssertTrue(store.save("sk-original"))

        backing.addStatus = errSecInteractionNotAllowed  // e.g. the keychain locked meanwhile
        XCTAssertFalse(store.save("sk-replacement"))

        XCTAssertEqual(store.load(), "sk-original")
    }

    func testSaveEmptyStringIsStored() {
        // An empty string is still valid UTF-8, so this is a successful save of an empty
        // value — not a failure. The failure path is the keychain rejecting the add.
        let store = makeStore(backing: FakeKeychain())

        XCTAssertTrue(store.save(""))
        XCTAssertEqual(store.load(), "")
    }

    func testLoadReturnsNilWhenNothingStored() {
        XCTAssertNil(makeStore(backing: FakeKeychain()).load())
    }

    func testLoadReturnsNilWhenKeychainErrors() {
        let backing = FakeKeychain()
        backing.copyStatus = errSecInteractionNotAllowed
        XCTAssertNil(makeStore(backing: backing).load())
    }

    func testDeleteRemovesStoredKey() {
        let backing = FakeKeychain()
        let store = makeStore(backing: backing)

        XCTAssertTrue(store.save("sk-test"))
        XCTAssertTrue(store.delete())
        XCTAssertNil(store.load())
    }

    func testDeleteOfMissingItemSucceeds() {
        // Deleting something that was never there is not an error.
        XCTAssertTrue(makeStore(backing: FakeKeychain()).delete())
    }

    func testDeleteReturnsFalseOnRealFailure() {
        let backing = FakeKeychain()
        backing.deleteStatus = errSecInteractionNotAllowed
        XCTAssertFalse(makeStore(backing: backing).delete())
    }
}

// MARK: - Fake keychain

/// An in-memory stand-in for the `SecItem*` API, with overridable statuses so the failure
/// paths can be exercised. Never touches the real keychain.
final class FakeKeychain {
    /// When set, `add` fails with this status instead of storing.
    var addStatus: OSStatus?
    /// When set, `copyMatching` fails with this status instead of reading.
    var copyStatus: OSStatus?
    /// When set, `delete` fails with this status instead of removing.
    var deleteStatus: OSStatus?

    private(set) var addCallCount = 0
    private(set) var deleteCallCount = 0

    private var storage: [String: Data] = [:]

    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        addCallCount += 1
        if let addStatus { return addStatus }

        let attributes = Self.attributes(from: query)
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data
        else { return errSecParam }

        guard storage[account] == nil else { return errSecDuplicateItem }
        storage[account] = data
        return errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        if let copyStatus { return copyStatus }

        let attributes = Self.attributes(from: query)
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let data = storage[account]
        else { return errSecItemNotFound }

        result?.pointee = data as CFData
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        deleteCallCount += 1
        if let deleteStatus { return deleteStatus }

        let attributes = Self.attributes(from: query)
        guard let account = attributes[kSecAttrAccount as String] as? String,
              storage.removeValue(forKey: account) != nil
        else { return errSecItemNotFound }

        return errSecSuccess
    }

    private static func attributes(from query: CFDictionary) -> [String: Any] {
        (query as NSDictionary) as? [String: Any] ?? [:]
    }
}

// MARK: - Stub URLProtocol

/// Serves canned responses to `URLSession` so the retry logic can be driven without a network.
final class StubURLProtocol: URLProtocol {

    enum Outcome {
        case status(Int, Data)
        case failure(Error)
    }

    private enum StubError: Error {
        case noOutcomeConfigured
        case missingURL
    }

    private static let lock = NSLock()
    private static var outcomes: [Outcome] = []
    private static var lastOutcome: Outcome?
    private static var requests: [URLRequest] = []
    private static var bodies: [Data?] = []

    /// Queues the outcomes for successive requests. Once the queue is drained the final
    /// outcome repeats, so a persistent failure needs only one entry.
    static func enqueue(_ outcomes: Outcome...) {
        lock.lock()
        defer { lock.unlock() }
        Self.outcomes.append(contentsOf: outcomes)
    }

    /// Queues an outcome for a specific URL path. URL-matched outcomes are consumed
    /// before the FIFO queue, so concurrent requests to different endpoints each get
    /// the right response regardless of arrival order.
    static func enqueue(_ outcome: Outcome, forURLPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        urlMatchedOutcomes[path] = outcome
    }

    private static var urlMatchedOutcomes: [String: Outcome] = [:]

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        outcomes = []
        urlMatchedOutcomes = [:]
        lastOutcome = nil
        requests = []
        bodies = []
    }

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// The recorded requests' bodies, in the same order. Captured here rather than read
    /// from `URLRequest.httpBody` afterwards, because `URLSession` hands a protocol the
    /// body as a stream — one that has to be drained while the request is being loaded.
    static var recordedBodies: [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    static var requestCount: Int {
        recordedRequests.count
    }

    /// Records the request and pops the outcome that should answer it.
    /// URL-matched outcomes take priority over the FIFO queue, so concurrent
    /// requests to different endpoints each get the right response.
    private static func nextOutcome(for request: URLRequest) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        bodies.append(drainBody(from: request))

        if let path = request.url?.path,
           let matched = urlMatchedOutcomes[path] {
            return matched
        }

        if !outcomes.isEmpty {
            lastOutcome = outcomes.removeFirst()
        }
        return lastOutcome ?? .failure(StubError.noOutcomeConfigured)
    }

    private static func drainBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            body.append(buffer, count: read)
        }
        return body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.nextOutcome(for: request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)

        case .status(let statusCode, let body):
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: StubError.missingURL)
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - Mock CreditsChecker

/// A mock `CreditsChecking` implementation for testing the ViewModel.
final class MockCreditsChecker: CreditsChecking {
    var balanceToReturn: Int?
    var errorToThrow: Error?

    init(balanceToReturn: Int? = nil, errorToThrow: Error? = nil) {
        self.balanceToReturn = balanceToReturn
        self.errorToThrow = errorToThrow
    }

    func fetchBalance(apiKey: String) async throws -> Int {
        if let errorToThrow {
            throw errorToThrow
        }
        return balanceToReturn ?? 0
    }
}
