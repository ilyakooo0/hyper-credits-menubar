import Foundation

// MARK: - Usage

/// Usage data from z.ai's coding plan API — two endpoints that together give the
/// plan level, the 5-hour token quota, and the weekly token quota.
///
/// Every field in the report is optional. The quota endpoint may return fewer limits
/// than expected, and the subscription endpoint may return an empty list, so an
/// unrecognized shape degrades to "nothing to show" rather than failing the decode.
struct ZaiUsageReport: Equatable {
    /// Percent of the 5-hour token window consumed, 0–100.
    let fiveHourPercent: Int?
    /// Percent of the weekly token window consumed, 0–100.
    let weeklyPercent: Int?
    /// When the 5-hour window resets, or `nil` when not provided.
    let fiveHourResetsAt: Date?
    /// When the weekly window resets, or `nil` when not provided.
    let weeklyResetsAt: Date?
    /// The plan tier from the quota response: `"lite"`, `"pro"`, `"max"`.
    let planLevel: String?

    /// Whether there is anything at all to render. A report with all-nil fields reads
    /// as a section header over nothing, which looks like a bug.
    var isEmpty: Bool {
        fiveHourPercent == nil && weeklyPercent == nil && planLevel == nil
    }
}

// MARK: - API Response Models

/// Response from `GET https://api.z.ai/api/monitor/usage/quota/limit`.
struct ZaiQuotaResponse: Decodable, Equatable {
    let code: Int
    let msg: String?
    let data: ZaiQuotaData?
    let success: Bool

    private enum CodingKeys: String, CodingKey {
        case code, msg, data, success
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        msg = try container.decodeIfPresent(String.self, forKey: .msg)
        data = try container.decodeIfPresent(ZaiQuotaData.self, forKey: .data)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
    }
}

struct ZaiQuotaData: Decodable, Equatable {
    let limits: [ZaiLimit]?
    let level: String?

    private enum CodingKeys: String, CodingKey {
        case limits, level
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = try container.decodeIfPresent([ZaiLimit].self, forKey: .limits)
        level = try container.decodeIfPresent(String.self, forKey: .level)
    }
}

/// One limit entry from the quota response.
///
/// `unit` identifies the window: 3 = 5-hour, 6 = weekly, 5 = monthly tools.
/// `type` is `"TOKENS_LIMIT"` for token quotas or `"TIME_LIMIT"` for tool-call quotas.
struct ZaiLimit: Decodable, Equatable {
    let type: String
    let unit: Int
    let percentage: Int
    /// Epoch milliseconds, or `nil` when nothing has been used.
    let nextResetTime: Int64?

    private enum CodingKeys: String, CodingKey {
        case type, unit, percentage, nextResetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        unit = try container.decodeIfPresent(Int.self, forKey: .unit) ?? 0
        // Decoded as Double and rounded: the field is documented as an integer, but
        // a fractional value would throw and take the whole payload down with it.
        let rawPercent = try container.decodeIfPresent(Double.self, forKey: .percentage) ?? 0
        percentage = Int(rawPercent.rounded())
        nextResetTime = try container.decodeIfPresent(Int64.self, forKey: .nextResetTime)
    }

    init(type: String, unit: Int, percentage: Int, nextResetTime: Int64? = nil) {
        self.type = type
        self.unit = unit
        self.percentage = percentage
        self.nextResetTime = nextResetTime
    }
}

/// Response from `GET https://api.z.ai/api/biz/subscription/list`.
struct ZaiSubscriptionResponse: Decodable, Equatable {
    let code: Int
    let data: [ZaiSubscription]?
    let success: Bool

    private enum CodingKeys: String, CodingKey {
        case code, data, success
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        data = try container.decodeIfPresent([ZaiSubscription].self, forKey: .data)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
    }
}

struct ZaiSubscription: Decodable, Equatable {
    let productName: String?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case productName, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        status = try container.decodeIfPresent(String.self, forKey: .status)
    }

    init(productName: String? = nil, status: String? = nil) {
        self.productName = productName
        self.status = status
    }
}

// MARK: - Errors

/// Errors that can occur while fetching z.ai usage.
enum ZaiUsageError: LocalizedError, Equatable {
    /// No API key has been entered. Not an error the user needs to see — the popover
    /// just leaves the section out, same as missing Claude credentials.
    case noAPIKey

    /// The API key was rejected by z.ai.
    case invalidAPIKey
    case requestFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return nil
        case .invalidAPIKey:
            return "z.ai API key is invalid. Check your key at z.ai/manage-apikey/coding-plan/personal/my-plan"
        case .requestFailed(let message):
            return "z.ai request failed: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode z.ai usage: \(message)"
        }
    }
}

// MARK: - Protocol

/// Protocol abstraction for fetching z.ai usage, enabling test injection.
protocol ZaiUsageChecking {
    func fetchUsage(apiKey: String) async throws -> ZaiUsageReport
}

// MARK: - Client

/// Client for z.ai's coding plan usage API, authenticating with an API key the user
/// enters in settings (stored in Keychain, separate from the Hyper key).
///
/// Fetches the quota/limit and subscription endpoints concurrently to get both usage
/// percentages and the plan tier in one round-trip. Retries transient failures with
/// exponential backoff, same pattern as `CreditsChecker` and `ClaudeUsageClient`.
actor ZaiUsageClient: ZaiUsageChecking {
    static let baseURL = URL(string: "https://api.z.ai/api")!
    static let quotaEndpoint = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let subscriptionEndpoint = URL(string: "https://api.z.ai/api/biz/subscription/list")!

    /// Retries *after* the initial attempt, so at most 3 requests per call.
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

    /// Client-error status codes that are nonetheless worth retrying: both are the
    /// server telling us to come back later, not that the request itself is wrong.
    private static let retryableStatusCodes: Set<Int> = [
        408,  // Request Timeout
        429,  // Too Many Requests
    ]

    private let session: URLSession
    private let retryBaseDelay: Duration

    /// - Parameters:
    ///   - retryBaseDelay: Delay before the first retry; doubles on each subsequent
    ///     one (2s, then 4s). Injectable so tests need not wait in real time.
    init(
        session: URLSession? = nil,
        retryBaseDelay: Duration = .seconds(2)
    ) {
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

    /// Fetches current usage with the given API key.
    ///
    /// The quota and subscription endpoints are fetched concurrently; neither waits on
    /// the other. The subscription endpoint is best-effort — if it fails, the plan
/// level from the quota response (`data.level`) is used instead.
    ///
    /// - Throws: `ZaiUsageError`. `.noAPIKey` means no key was provided, which callers
    ///   should treat as "nothing to show" rather than as a failure.
    func fetchUsage(apiKey: String) async throws -> ZaiUsageReport {
        guard !apiKey.isEmpty else { throw ZaiUsageError.noAPIKey }

    async let quotaOutcome = fetchQuota(apiKey: apiKey)
    async let subscriptionOutcome = fetchSubscription(apiKey: apiKey)

        let quota = try await quotaOutcome
        let subscription = try? await subscriptionOutcome

        // Extract percentages from the limits array.
        var fiveHourPercent: Int?
        var weeklyPercent: Int?
        var fiveHourResetsAt: Date?
        var weeklyResetsAt: Date?

        for limit in quota?.limits ?? [] {
            switch limit.unit {
            case 3: // 5-hour window
                fiveHourPercent = limit.percentage
                fiveHourResetsAt = limit.nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            case 6: // weekly window
                weeklyPercent = limit.percentage
                weeklyResetsAt = limit.nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            default:
                break
            }
        }

        // Plan level: prefer the product name from the subscription, fall back to the
        // quota response's `level` field.
        var planLevel: String? = quota?.level
        if let sub = subscription?.data?.first(where: { $0.status == "VALID" }),
           let name = sub.productName {
            planLevel = name
        }

        return ZaiUsageReport(
            fiveHourPercent: fiveHourPercent,
            weeklyPercent: weeklyPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            planLevel: planLevel
        )
    }

    // MARK: - Quota Request

    private func fetchQuota(apiKey: String) async throws -> ZaiQuotaData? {
        var request = URLRequest(url: Self.quotaEndpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await send(request)

        do {
            let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: data)
            guard response.success else {
                throw ZaiUsageError.requestFailed(response.msg ?? "Unknown error")
            }
            return response.data
        } catch let error as ZaiUsageError {
            throw error
        } catch {
            throw ZaiUsageError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Subscription Request

    private func fetchSubscription(apiKey: String) async throws -> ZaiSubscriptionResponse {
        var request = URLRequest(url: Self.subscriptionEndpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await send(request)

        do {
            return try JSONDecoder().decode(ZaiSubscriptionResponse.self, from: data)
        } catch {
            throw ZaiUsageError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Transport

    /// Sends a request, retrying transient failures with exponential backoff.
    private func send(_ request: URLRequest) async throws -> Data {
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

    /// Performs a single request, tagging the failure with whether a retry could
    /// plausibly help.
    private func performAttempt(_ request: URLRequest) async throws -> Data {
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
            return data
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
    }

    /// A failed attempt, carrying the error to surface plus whether retrying is worthwhile.
    private struct AttemptFailure: Error {
        let underlying: ZaiUsageError
        let isRetryable: Bool
    }
}