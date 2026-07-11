import Foundation

/// JSON response from `GET https://hyper.charm.land/v1/credits`.
///
/// The API is documented to return an integer balance, but tolerates a fractional
/// one (`{"balance": 42.5}`) by rounding to the nearest integer.
struct BalanceResponse: Decodable, Equatable {
    let balance: Int

    init(balance: Int) {
        self.balance = balance
    }

    private enum CodingKeys: String, CodingKey {
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try Int first so large values keep their exact magnitude; only fall back to
        // Double when the payload is genuinely fractional.
        if let exact = try? container.decode(Int.self, forKey: .balance) {
            balance = exact
            return
        }

        let fractional = try container.decode(Double.self, forKey: .balance)
        guard let rounded = Int(exactly: fractional.rounded(.toNearestOrAwayFromZero)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .balance,
                in: container,
                debugDescription: "Balance \(fractional) is not representable as an integer."
            )
        }
        balance = rounded
    }
}

/// Errors that can occur while fetching the balance.
enum CreditsError: LocalizedError, Equatable {
    case noAPIKey
    case invalidAPIKey
    case requestFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key set. Enter your Hyper API key in settings."
        case .invalidAPIKey:
            return "Invalid API key. Check your key at hyper.charm.land"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode response: \(message)"
        }
    }
}

/// Protocol abstraction for fetching credit balance, enabling test injection.
protocol CreditsChecking {
    func fetchBalance(apiKey: String) async throws -> Int
}

/// Client for the Hyper (Charm) credits API.
final class CreditsChecker: CreditsChecking {
    static let endpoint = URL(string: "https://hyper.charm.land/v1/credits")!

    /// Number of retries *after* the initial attempt, so at most 3 requests total.
    static let maxRetries = 2

    /// URL error codes worth retrying: the request never reached a server that had an
    /// opinion about it, so the same request may well succeed a moment later.
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .badServerResponse,
    ]

    /// Client-error status codes that are nonetheless worth retrying: both are the server
    /// telling us to come back later rather than that the request itself is wrong.
    private static let retryableStatusCodes: Set<Int> = [
        408,  // Request Timeout
        429,  // Too Many Requests
    ]

    private let session: URLSession
    private let retryBaseDelay: Duration

    /// - Parameter retryBaseDelay: Delay before the first retry; doubles on each
    ///   subsequent one (2s, then 4s). Injectable so tests need not wait in real time.
    init(session: URLSession? = nil, retryBaseDelay: Duration = .seconds(2)) {
        self.retryBaseDelay = retryBaseDelay
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches the current credit balance for the given API key.
    ///
    /// Transient failures (network errors, 5xx) are retried up to `maxRetries` times with
    /// exponential backoff. Authentication and other client errors fail immediately.
    ///
    /// - Parameter apiKey: A Hyper API key (starts with `"sk-"`).
    /// - Returns: The balance as an integer.
    /// - Throws: `CreditsError` on failure.
    func fetchBalance(apiKey: String) async throws -> Int {
        guard !apiKey.isEmpty else { throw CreditsError.noAPIKey }

        let request = makeRequest(apiKey: apiKey)
        var attempt = 0

        while true {
            do {
                return try await performAttempt(request)
            } catch let failure as AttemptFailure {
                guard failure.isRetryable, attempt < Self.maxRetries else {
                    throw failure.underlying
                }
                try await Task.sleep(for: retryBaseDelay * (1 << attempt))
                attempt += 1
            }
        }
    }

    private func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    /// Performs a single request, tagging the failure with whether a retry could plausibly help.
    private func performAttempt(_ request: URLRequest) async throws -> Int {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw AttemptFailure(
                underlying: .requestFailed(urlError.localizedDescription),
                isRetryable: Self.retryableURLErrorCodes.contains(urlError.code)
            )
        } catch {
            throw AttemptFailure(
                underlying: .requestFailed(error.localizedDescription),
                isRetryable: false
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttemptFailure(underlying: .requestFailed("Invalid response type"), isRetryable: false)
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw AttemptFailure(underlying: .invalidAPIKey, isRetryable: false)
        case 500...599:
            throw AttemptFailure(
                underlying: .requestFailed("HTTP \(httpResponse.statusCode)"),
                isRetryable: true
            )
        default:
            throw AttemptFailure(
                underlying: .requestFailed("HTTP \(httpResponse.statusCode)"),
                isRetryable: Self.retryableStatusCodes.contains(httpResponse.statusCode)
            )
        }

        do {
            return try JSONDecoder().decode(BalanceResponse.self, from: data).balance
        } catch {
            throw AttemptFailure(underlying: .decodingFailed(error.localizedDescription), isRetryable: false)
        }
    }

    /// A failed attempt, carrying the error to surface plus whether retrying is worthwhile.
    private struct AttemptFailure: Error {
        let underlying: CreditsError
        let isRetryable: Bool
    }
}
