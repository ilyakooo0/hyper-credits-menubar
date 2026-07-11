import Foundation

// MARK: - Usage

/// Usage data from `GET https://api.anthropic.com/api/oauth/usage` — the endpoint
/// behind Claude Code's own `/usage` command.
///
/// Every field is optional. The payload varies by plan, and Anthropic adds and
/// removes windows without notice, so an unrecognized shape has to degrade to
/// "nothing to show" rather than fail the whole decode.
struct ClaudeUsage: Decodable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let limits: [Limit]?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case limits
    }

    /// The limit the server itself flags as currently binding — the one worth leading
    /// with. `nil` when it flags none, which is the normal state below the thresholds.
    var activeLimit: Limit? {
        limits?.first { $0.isActive }
    }

    /// Whether there is anything at all to render. The endpoint answers `{}` for an
    /// account that has never used the plan, and a section header over nothing reads
    /// as a bug.
    var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil && sevenDayOpus == nil && (limits?.isEmpty ?? true)
    }
}

/// One usage window, e.g. the rolling 5-hour or 7-day allowance.
struct UsageWindow: Decodable, Equatable, ResetCountdown {
    /// Percent of the window consumed, 0–100.
    let utilization: Double

    /// ISO 8601, or `nil` when nothing has been used and so nothing is counting down.
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

/// One entry in the `limits` array: the server's own classification of a limit,
/// including whether it is the one currently in effect.
struct Limit: Decodable, Equatable, ResetCountdown {
    let percent: Int
    let resetsAt: String?
    let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case percent
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    init(percent: Int, resetsAt: String? = nil, isActive: Bool = false) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded as a Double and rounded: the field is documented as an integer, but
        // decoding it as one would throw on a fractional value and take the whole
        // payload down with it.
        let rawPercent = try container.decodeIfPresent(Double.self, forKey: .percent) ?? 0
        percent = Int(rawPercent.rounded())
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }
}

// MARK: - Reset Countdown

/// Anything carrying an ISO 8601 reset timestamp, and so able to render a countdown.
protocol ResetCountdown {
    var resetsAt: String? { get }
}

extension ResetCountdown {
    /// `resetsAt` as a date, or `nil` when absent or unparseable.
    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601.date(from: resetsAt)
    }

    /// How long until the window resets, e.g. `"3h 20m"`, `"1d 4h"` or `"12m"`.
    /// `nil` once the reset time has passed, or when there is no timestamp at all.
    ///
    /// - Parameter reference: The instant to count from. Injectable for tests.
    func resetsIn(from reference: Date = Date()) -> String? {
        guard let date = resetsAtDate else { return nil }

        let interval = date.timeIntervalSince(reference)
        guard interval > 0 else { return nil }

        // Rounded to the nearest second, so a window that is exactly "3h 20m" out
        // isn't reported a minute short because of the milliseconds spent getting here.
        let seconds = Int(interval.rounded())
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// The countdown as of now.
    var resetsInFormatted: String? {
        resetsIn()
    }
}

/// Claude timestamps carry fractional seconds, but not always — both spellings parse.
private enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }
}

// MARK: - Credentials

/// The OAuth credentials the Claude Code CLI owns. The key names are Claude Code's,
/// not ours — this is its blob, and we only ever read it and rotate its tokens.
struct ClaudeOAuthCredentials: Codable, Equatable {
    var claudeAiOauth: OAuthToken

    struct OAuthToken: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        /// Epoch milliseconds.
        var expiresAt: Int64
        var scopes: [String]?
        /// `"pro"`, `"max"`, `"team"`, …
        var subscriptionType: String?
        var rateLimitTier: String?
    }
}

/// Where credentials were read from, so a rotated token is written back to the same
/// place. Writing to the other one would leave Claude Code holding a refresh token
/// the server has already retired — i.e. would sign the user out of their own CLI.
enum ClaudeCredentialSource: Equatable {
    case keychain(account: String)
    case file(URL)
}

/// Credentials together with where they came from.
struct StoredClaudeCredentials: Equatable {
    var credentials: ClaudeOAuthCredentials
    var source: ClaudeCredentialSource
}

/// Reads — and, after a token refresh, writes back — the credentials Claude Code owns.
/// Injectable so tests never go near the real Keychain or the real credentials file.
protocol ClaudeCredentialStoring {
    func load() -> StoredClaudeCredentials?

    /// Best effort: failing to persist a refreshed token is not worth failing the
    /// fetch over, and the next launch will simply refresh again.
    func save(_ stored: StoredClaudeCredentials)
}

/// The real store: Claude Code's login-Keychain item, falling back to
/// `~/.claude/.credentials.json`.
///
/// The Keychain item belongs to Claude Code, so it is read through the `security`
/// CLI rather than `SecItemCopyMatching`: the item's ACL trusts `/usr/bin/security`,
/// and macOS asks the user once to allow it. Spawning a process and reading a file in
/// the user's home is also why this app cannot be sandboxed.
struct ClaudeCodeCredentialStore: ClaudeCredentialStoring {
    static let defaultKeychainService = "Claude Code-credentials"

    /// `NSHomeDirectory()` rather than `FileManager.homeDirectoryForCurrentUser`: the
    /// latter can resolve to a container path, while Claude Code always writes to the
    /// real home directory.
    static var defaultCredentialsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
    }

    private let keychainService: String
    private let credentialsFile: URL

    init(
        keychainService: String = ClaudeCodeCredentialStore.defaultKeychainService,
        credentialsFile: URL = ClaudeCodeCredentialStore.defaultCredentialsFile
    ) {
        self.keychainService = keychainService
        self.credentialsFile = credentialsFile
    }

    func load() -> StoredClaudeCredentials? {
        if let json = Self.runSecurity(["find-generic-password", "-s", keychainService, "-w"]),
           let credentials = Self.decode(Data(json.utf8)) {
            return StoredClaudeCredentials(
                credentials: credentials,
                source: .keychain(account: keychainAccount())
            )
        }

        guard let data = try? Data(contentsOf: credentialsFile),
              let credentials = Self.decode(data) else { return nil }

        return StoredClaudeCredentials(credentials: credentials, source: .file(credentialsFile))
    }

    func save(_ stored: StoredClaudeCredentials) {
        guard let json = rotatedJSON(for: stored) else { return }

        switch stored.source {
        case .keychain(let account):
            _ = Self.runSecurity([
                "add-generic-password",
                "-U",  // update the existing item rather than adding a second one
                "-s", keychainService,
                "-a", account,
                "-w", json,
            ])

        case .file(let url):
            guard let data = json.data(using: .utf8) else { return }
            try? data.write(to: url, options: .atomic)
            // An atomic write replaces the file, so the 0600 mode has to be reapplied.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    /// The stored blob with only the three token fields rotated.
    ///
    /// Patches the raw JSON rather than re-encoding `ClaudeOAuthCredentials`, because
    /// a round-trip through our own type would silently drop any field Anthropic adds
    /// to the blob that we don't model — and this is the file the user's CLI logs in
    /// with. Re-encoding is the fallback for when the raw blob can't be read back.
    private func rotatedJSON(for stored: StoredClaudeCredentials) -> String? {
        let token = stored.credentials.claudeAiOauth

        if let raw = rawJSON(from: stored.source),
           let parsed = try? JSONSerialization.jsonObject(with: raw),
           var object = parsed as? [String: Any],
           var oauth = object["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = token.accessToken
            oauth["refreshToken"] = token.refreshToken
            oauth["expiresAt"] = token.expiresAt
            object["claudeAiOauth"] = oauth

            if let patched = try? JSONSerialization.data(withJSONObject: object),
               let json = String(data: patched, encoding: .utf8) {
                return json
            }
        }

        guard let encoded = try? JSONEncoder().encode(stored.credentials) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private func rawJSON(from source: ClaudeCredentialSource) -> Data? {
        switch source {
        case .keychain:
            return Self.runSecurity(["find-generic-password", "-s", keychainService, "-w"])
                .map { Data($0.utf8) }
        case .file(let url):
            return try? Data(contentsOf: url)
        }
    }

    /// The account on Claude Code's Keychain item, so a write-back updates that item
    /// instead of adding a second one under a different account.
    private func keychainAccount() -> String {
        guard let output = Self.runSecurity(["find-generic-password", "-s", keychainService]) else {
            return NSUserName()
        }

        // The attribute dump spells the account as: "acct"<blob>="someone"
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"acct\""),
                  let range = trimmed.range(of: #"="[^"]+"#, options: .regularExpression)
            else { continue }
            // The match starts at `="` and stops before the closing quote.
            return String(trimmed[range].dropFirst(2))
        }

        return NSUserName()
    }

    private static func decode(_ data: Data) -> ClaudeOAuthCredentials? {
        try? JSONDecoder().decode(ClaudeOAuthCredentials.self, from: data)
    }

    /// Runs `/usr/bin/security`, returning its trimmed stdout, or `nil` when it fails
    /// or says nothing — which is the ordinary answer when Claude Code was never
    /// signed in on this machine.
    private static func runSecurity(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        // Discarded rather than piped: an undrained error pipe can fill and deadlock.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drained before waiting, for the same reason.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Errors

/// Errors that can occur while fetching Claude usage.
enum ClaudeUsageError: LocalizedError, Equatable {
    /// Claude Code has never signed in here. Not an error the user needs to see — the
    /// popover just leaves the section out.
    case noCredentials
    case invalidCredentials
    case tokenRefreshFailed
    case requestFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude Code credentials found. Run `claude` in a terminal to sign in."
        case .invalidCredentials:
            return "Claude sign-in expired. Run `claude` in a terminal to sign in again."
        case .tokenRefreshFailed:
            return "Could not refresh Claude credentials. Run `claude` in a terminal to sign in again."
        case .requestFailed(let message):
            return "Claude request failed: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode Claude usage: \(message)"
        }
    }
}

/// What a successful fetch yields: the usage itself, plus the plan it belongs to.
struct ClaudeUsageReport: Equatable {
    let usage: ClaudeUsage

    /// `"pro"`, `"max"`, … straight from the OAuth credentials; `nil` when absent.
    let subscriptionType: String?
}

/// Protocol abstraction for fetching Claude usage, enabling test injection.
protocol ClaudeUsageChecking {
    func fetchUsage() async throws -> ClaudeUsageReport
}

// MARK: - Client

/// Client for Claude Code's subscription usage API, authenticating with the OAuth
/// credentials the CLI already stores on this machine.
///
/// An actor rather than a plain client, because the refresh path mutates state the
/// user's CLI depends on: the token endpoint rotates the refresh token, so two
/// concurrent refreshes would leave one of them holding a token the server has
/// already retired. Overlapping fetches (timer, manual click, wake) instead join a
/// single in-flight refresh.
actor ClaudeUsageClient: ClaudeUsageChecking {
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Claude Code's public OAuth client id, and the scopes it signs in with.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scope = "user:inference user:profile user:sessions:claude_code"

    /// Cloudflare fronts the token endpoint and answers 403 `browser_signature_banned`
    /// to anything without a browser User-Agent.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    /// Refresh this far ahead of the stated expiry rather than racing it.
    static let expiryBuffer: TimeInterval = 60

    /// Used when the token endpoint omits `expires_in`.
    static let defaultTokenLifetime: TimeInterval = 8 * 60 * 60

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
    private let store: ClaudeCredentialStoring
    private let retryBaseDelay: Duration
    private let now: @Sendable () -> Date

    /// The refresh currently in flight, if any. See `refreshCredentials(from:)`.
    private var inFlightRefresh: Task<StoredClaudeCredentials, Error>?

    /// - Parameters:
    ///   - retryBaseDelay: Delay before the first retry; doubles on each subsequent
    ///     one (2s, then 4s). Injectable so tests need not wait in real time.
    ///   - now: The current instant. Injectable so tests can drive token expiry.
    init(
        session: URLSession? = nil,
        store: ClaudeCredentialStoring = ClaudeCodeCredentialStore(),
        retryBaseDelay: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.retryBaseDelay = retryBaseDelay
        self.now = now
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches current usage, refreshing the OAuth token first if it has expired.
    ///
    /// - Throws: `ClaudeUsageError`. `.noCredentials` means Claude Code was never
    ///   signed in here, which callers should treat as "nothing to show" rather than
    ///   as a failure.
    func fetchUsage() async throws -> ClaudeUsageReport {
        guard let stored = store.load() else { throw ClaudeUsageError.noCredentials }

        var current = stored
        var didRefresh = false
        if isExpired(stored.credentials) {
            current = try await refreshCredentials(from: stored)
            didRefresh = true
        }

        do {
            return try await report(with: current)
        } catch ClaudeUsageError.invalidCredentials where !didRefresh {
            // A token can be revoked server-side well before its stated expiry, so a
            // rejection is worth one refresh and one retry.
            guard let refreshed = try? await refreshCredentials(from: current) else {
                // A failed refresh (Cloudflare, a retired refresh token) says less
                // than the rejection that sent us here, so surface that instead.
                throw ClaudeUsageError.invalidCredentials
            }
            return try await report(with: refreshed)
        }
    }

    // MARK: - Usage Request

    private func report(with stored: StoredClaudeCredentials) async throws -> ClaudeUsageReport {
        let token = stored.credentials.claudeAiOauth
        let usage = try await requestUsage(token: token.accessToken)
        return ClaudeUsageReport(usage: usage, subscriptionType: token.subscriptionType)
    }

    private func requestUsage(token: String) async throws -> ClaudeUsage {
        var request = URLRequest(url: Self.usageEndpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await send(request)

        do {
            return try JSONDecoder().decode(ClaudeUsage.self, from: data)
        } catch {
            throw ClaudeUsageError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Token Refresh

    /// Exchanges the refresh token for a fresh access token and persists the result.
    ///
    /// Callers join whatever refresh is already running rather than starting a second
    /// one, and the exchange itself runs in an unstructured task so that a cancelled
    /// caller — the view model cancels the previous refresh whenever a new one starts
    /// — can never abandon a rotation half-done, with the new refresh token neither
    /// used nor written back.
    private func refreshCredentials(from stored: StoredClaudeCredentials) async throws -> StoredClaudeCredentials {
        if let existing = inFlightRefresh {
            return try await existing.value
        }

        let task = Task { () throws -> StoredClaudeCredentials in
            let response = try await self.requestTokenRefresh(
                refreshToken: stored.credentials.claudeAiOauth.refreshToken
            )

            var refreshed = stored
            refreshed.credentials.claudeAiOauth.accessToken = response.accessToken
            if let rotated = response.refreshToken {
                refreshed.credentials.claudeAiOauth.refreshToken = rotated
            }
            let lifetime = response.expiresIn.map(TimeInterval.init) ?? Self.defaultTokenLifetime
            refreshed.credentials.claudeAiOauth.expiresAt =
                Int64((self.now().timeIntervalSince1970 + lifetime) * 1000)

            self.store.save(refreshed)
            return refreshed
        }
        // Only the task's creator ever clears the slot, so a joiner resuming late can
        // never wipe out a refresh that started after it.
        inFlightRefresh = task

        do {
            let refreshed = try await task.value
            inFlightRefresh = nil
            return refreshed
        } catch {
            inFlightRefresh = nil
            throw error
        }
    }

    /// Posts the refresh grant as JSON, then — for token endpoints that reject a JSON
    /// body — retries the same exchange form-encoded before giving up.
    private func requestTokenRefresh(refreshToken: String) async throws -> TokenRefreshResponse {
        let parameters = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scope,
        ]

        if let response = await tokenRefreshAttempt(parameters: parameters, formEncoded: false) {
            return response
        }
        if let response = await tokenRefreshAttempt(parameters: parameters, formEncoded: true) {
            return response
        }
        throw ClaudeUsageError.tokenRefreshFailed
    }

    /// One refresh exchange in one encoding. Returns `nil` rather than throwing, so the
    /// caller can fall through to the other encoding.
    private func tokenRefreshAttempt(
        parameters: [String: String],
        formEncoded: Bool
    ) async -> TokenRefreshResponse? {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if formEncoded {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formURLEncoded(parameters).data(using: .utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        }

        guard let data = try? await send(request) else { return nil }
        return try? JSONDecoder().decode(TokenRefreshResponse.self, from: data)
    }

    /// Whether the access token is spent, or close enough that using it would be a race.
    private func isExpired(_ credentials: ClaudeOAuthCredentials) -> Bool {
        let expiry = Date(
            timeIntervalSince1970: TimeInterval(credentials.claudeAiOauth.expiresAt) / 1000
        )
        return expiry.timeIntervalSince(now()) <= Self.expiryBuffer
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
        case 401, 403:
            throw AttemptFailure(underlying: .invalidCredentials, isRetryable: false)
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

    /// Encodes parameters as an `application/x-www-form-urlencoded` body. Percent-encodes
    /// against RFC 3986's unreserved set, so the spaces and colons in the scope don't
    /// travel raw.
    private static func formURLEncoded(_ parameters: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        return parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    }

    /// A failed attempt, carrying the error to surface plus whether retrying is worthwhile.
    private struct AttemptFailure: Error {
        let underlying: ClaudeUsageError
        let isRetryable: Bool
    }
}

/// The token endpoint's answer to a refresh grant.
struct TokenRefreshResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String?

    /// Seconds. Omitted by some deployments, in which case the caller assumes a default.
    let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
