import Foundation

// In-app Claude lane: the Swift port of `bin/bloom-usage-fetch-claude-official
// --mode api`, so a buyer with no Node.js and no Python still gets the official
// Claude reading after Set up.
//
// Safety rules carried over from the Python fetch, unchanged:
// - Never refresh, write, or modify the OAuth token. Only Claude Code owns it.
//   The token is read the same way (CLAUDE_CODE_OAUTH_TOKEN first, then
//   `/usr/bin/security find-generic-password`), used for one GET, and dropped.
// - 401/403 is reported as `unauthorized`; it and every other durable failure
//   (no credential, offline, unparsed) back off for 10 minutes.
// - 429 backs off for Retry-After seconds (5 minutes when absent).
// - Scheduled fetches run at most once per 10 minutes. Refresh may go sooner,
//   never inside a 60-second floor, and never inside a 429 retry window.
//
// Writer coexistence: this reader writes only its own file,
// `claude-usage-native.json`, which UsageStore treats as one more Claude
// candidate (newest file wins). It stands down whenever the
// `com.codexusagehud.claude-writer` LaunchAgent is installed, or another
// producer (the statusline tap, a manual Python fetch) wrote
// `claude-usage.json` in the last 15 minutes. One producer feeds the lane at
// a time, and a Mac with the writer installed never runs this reader at all.

enum ClaudeNativeTrigger: String, Sendable {
    case scheduled
    case manual
    case setup
}

enum ClaudeNativeRunReport: Equatable, Sendable {
    case skipped(String)
    case fetched(status: String, message: String)

    var line: String {
        switch self {
        case .skipped(let reason): return "skipped (\(reason))"
        case .fetched(let status, let message): return "\(status): \(message)"
        }
    }
}

enum ClaudeOfficialUsageAPI {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"
    static let betaHeader = "oauth-2025-04-20"
    static let requestTimeout: TimeInterval = 10
    static let keychainTimeout: TimeInterval = 5
    /// Scheduled fetches never run more often than this (same value as the
    /// Python fetch's BLOOM_CLAUDE_OFFICIAL_MAX_AGE_SECONDS default).
    static let scheduledInterval: TimeInterval = 300
    /// A manual Refresh may skip the scheduled interval, not this floor.
    static let manualFloor: TimeInterval = 60
    static let rateLimitCooldown: TimeInterval = 300
    static let failureCooldown: TimeInterval = 600
    static let source = "claude-code-official-usage-api"
    static let producer = "usage-hud-app"
}

// MARK: - Parser (port of build_api_payload)

enum ClaudeOfficialUsageParser {
    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// ISO 8601 UTC with exactly three fractional digits and a trailing Z,
    /// the format the Python writer's iso_z_ms produces.
    static func isoZms(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Round to whole microseconds first (as Python's datetime does), then
        // truncate to milliseconds, so 0.123 never prints as .122.
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        var wholeSeconds = micros / 1_000_000
        var remainder = micros % 1_000_000
        if remainder < 0 { remainder += 1_000_000; wholeSeconds -= 1 }
        let millis = Int(remainder / 1000)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                        from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis
        )
    }

    /// Parses the endpoint's `resets_at` (ISO 8601, any fractional precision,
    /// `Z`, a numeric offset, or none for UTC), then rounds to the nearest
    /// minute: the endpoint reports 22:59:59.638 for a 23:00 reset.
    static func parseResetsAt(_ raw: Any?) -> Date? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let parsed = parseISO(text) else { return nil }
        let shifted = parsed.timeIntervalSince1970 + 30
        return Date(timeIntervalSince1970: floor(shifted / 60) * 60)
    }

    static func parseISO(_ text: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?)?(Z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        var components = DateComponents()
        components.year = Int(group(1) ?? "")
        components.month = Int(group(2) ?? "")
        components.day = Int(group(3) ?? "")
        components.hour = Int(group(4) ?? "0") ?? 0
        components.minute = Int(group(5) ?? "0") ?? 0
        components.second = Int(group(6) ?? "0") ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard components.year != nil, components.month != nil, components.day != nil,
              let base = calendar.date(from: components)
        else { return nil }
        var seconds = base.timeIntervalSince1970
        if let fraction = group(7) {
            seconds += (Double("0.\(fraction)") ?? 0)
        }
        if let zone = group(8), zone != "Z" {
            let sign: Double = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            let hours = Double(digits.prefix(2)) ?? 0
            let minutes = Double(digits.suffix(2)) ?? 0
            seconds -= sign * (hours * 3600 + minutes * 60)
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// "h:mm AM" in the given time zone, e.g. "2:19 AM".
    static func fiveHourResetLabel(_ date: Date, timeZone: TimeZone) -> String {
        let c = localComponents(date, timeZone: timeZone)
        let hour = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
        return String(format: "%d:%02d %@", hour, c.minute ?? 0, (c.hour ?? 0) < 12 ? "AM" : "PM")
    }

    /// "MMM d h AM" in the given time zone, e.g. "Sep 9 4 PM".
    static func weekResetLabel(_ date: Date, timeZone: TimeZone) -> String {
        let c = localComponents(date, timeZone: timeZone)
        let hour = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
        let month = monthAbbreviations[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(month) \(c.day ?? 0) \(hour) \((c.hour ?? 0) < 12 ? "AM" : "PM")"
    }

    private static func localComponents(_ date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    }

    static func windowMetric(label: String, usedPct: Any?, reset: Date?, capturedAt: Date, isFiveHour: Bool, timeZone: TimeZone) -> [String: Any] {
        var resetLabel: Any = NSNull()
        var resetAt: Any = NSNull()
        if let reset {
            resetLabel = isFiveHour ? fiveHourResetLabel(reset, timeZone: timeZone) : weekResetLabel(reset, timeZone: timeZone)
            resetAt = isoZms(reset)
        }
        return [
            "label": label,
            "usedPct": jsonNumber(usedPct) ?? NSNull(),
            "resetLabel": resetLabel,
            "resetAt": resetAt,
            "eventAt": isoZms(capturedAt),
        ]
    }

    /// The same snapshot shape the Python fetch builds from the endpoint body.
    /// Prefers `limits[]` (session, weekly_all, weekly_scoped); falls back to
    /// top-level `five_hour` / `seven_day`. Nil when neither has a window.
    static func buildPayload(body: [String: Any], capturedAt: Date, timeZone: TimeZone = .current) -> [String: Any]? {
        let limits = (body["limits"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let sessionItem = limits.first { ($0["kind"] as? String) == "session" }
        let weeklyAllItem = limits.first { ($0["kind"] as? String) == "weekly_all" }
        let scopedItems = limits.filter { ($0["kind"] as? String) == "weekly_scoped" }

        var currentSession: [String: Any]?
        var week: [String: Any]?
        var fable: [String: Any]?
        var skills: [[String: Any]] = []
        var rawLimits: [[String: Any]] = []
        let capturedISO = isoZms(capturedAt)

        if sessionItem != nil || weeklyAllItem != nil || !scopedItems.isEmpty {
            if let item = sessionItem {
                currentSession = windowMetric(label: "5-hour limit", usedPct: item["percent"], reset: parseResetsAt(item["resets_at"]),
                                              capturedAt: capturedAt, isFiveHour: true, timeZone: timeZone)
                rawLimits.append(item)
            }
            if let item = weeklyAllItem {
                week = windowMetric(label: "Weekly · all models", usedPct: item["percent"], reset: parseResetsAt(item["resets_at"]),
                                    capturedAt: capturedAt, isFiveHour: false, timeZone: timeZone)
                rawLimits.append(item)
            }
            for item in scopedItems {
                let scope = item["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let displayName = model?["display_name"] as? String
                let percent = item["percent"]
                rawLimits.append(item)
                if displayName == "Fable" {
                    var metric = windowMetric(label: "Fable weekly", usedPct: percent, reset: parseResetsAt(item["resets_at"]),
                                              capturedAt: capturedAt, isFiveHour: false, timeZone: timeZone)
                    // Own capture stamp, matching the Python path.
                    metric["capturedAt"] = capturedISO
                    fable = metric
                    if let number = jsonNumber(percent) {
                        skills.append(["name": "Limit · Fable weekly", "percent": number])
                    }
                } else if let displayName, !displayName.isEmpty, let number = jsonNumber(percent) {
                    skills.append(["name": "Limit · \(displayName) weekly", "percent": number])
                }
            }
        } else {
            if let fiveHour = body["five_hour"] as? [String: Any], !fiveHour.isEmpty {
                currentSession = windowMetric(label: "5-hour limit", usedPct: fiveHour["utilization"], reset: parseResetsAt(fiveHour["resets_at"]),
                                              capturedAt: capturedAt, isFiveHour: true, timeZone: timeZone)
                rawLimits.append(["kind": "session", "percent": fiveHour["utilization"] ?? NSNull(), "resets_at": fiveHour["resets_at"] ?? NSNull()])
            }
            if let sevenDay = body["seven_day"] as? [String: Any], !sevenDay.isEmpty {
                week = windowMetric(label: "Weekly · all models", usedPct: sevenDay["utilization"], reset: parseResetsAt(sevenDay["resets_at"]),
                                    capturedAt: capturedAt, isFiveHour: false, timeZone: timeZone)
                rawLimits.append(["kind": "weekly_all", "percent": sevenDay["utilization"] ?? NSNull(), "resets_at": sevenDay["resets_at"] ?? NSNull()])
            }
        }

        guard currentSession != nil || week != nil || fable != nil else { return nil }

        var payload: [String: Any] = [
            "schemaVersion": 1,
            "provider": "claude",
            "displayName": "Claude Code",
            "source": ClaudeOfficialUsageAPI.source,
            "sourceKind": "official_api",
            "confidence": "official",
            "confidenceNote": "Fetched from the usage endpoint Claude Code's /usage panel reads.",
            "updatedAt": capturedISO,
            "capturedAt": capturedISO,
            "eventAt": capturedISO,
            "health": ["verdict": "fresh", "reason": NSNull(), "checkedAt": capturedISO] as [String: Any],
            // The endpoint carries no driver breakdown.
            "contributors": [Any](),
        ]
        if let currentSession { payload["currentSession"] = currentSession }
        if let week { payload["week"] = week }
        if let fable { payload["weekFable"] = fable }
        if !skills.isEmpty { payload["skills"] = skills }

        var officialUsage: [String: Any] = [
            "capturedAt": capturedISO,
            "source": "api",
            "limits": rawLimits,
            "contributorsNote": "Driver breakdown is not part of the usage endpoint; Claude Code computes it from a local transcript scan.",
        ]
        if let extra = body["extra_usage"] as? [String: Any], !extra.isEmpty {
            officialUsage["extraUsage"] = [
                "enabled": extra["is_enabled"] ?? NSNull(),
                "usedCredits": extra["used_credits"] ?? NSNull(),
                "monthlyLimit": extra["monthly_limit"] ?? NSNull(),
            ] as [String: Any]
        }
        payload["officialUsage"] = officialUsage
        return payload
    }

    /// A JSON number from the endpoint, or nil (booleans are not percentages).
    static func jsonNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard number.doubleValue.isFinite else { return nil }
        return number
    }
}

// MARK: - Credential (port of resolve_credential)

enum ClaudeNativeCredential {
    struct CommandResult {
        var status: Int32
        var stdout: Data
    }

    /// CLAUDE_CODE_OAUTH_TOKEN first, then the `Claude Code-credentials`
    /// Keychain item for the login user, read with `/usr/bin/security` exactly
    /// as the Python fetch does (so the Keychain prompt behavior matches).
    /// Never reads or uses the refresh token.
    static func resolve(
        env: [String: String],
        account: String?,
        runSecurity: ([String]) -> CommandResult?
    ) -> String? {
        if let token = env["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return token }
        guard let account, !account.isEmpty else { return nil }
        guard let result = runSecurity(["find-generic-password", "-s", ClaudeOfficialUsageAPI.keychainService, "-a", account, "-w"]),
              result.status == 0
        else { return nil }
        planFieldsBox.set(planFields(fromKeychainValue: result.stdout))
        expiresBox.set(expiresAt(fromKeychainValue: result.stdout))
        return accessToken(fromKeychainValue: result.stdout)
    }

    /// The plan fields of the same Keychain item `resolve` reads for the
    /// usage endpoint (`subscriptionType`, `rateLimitTier`). Never the token.
    /// Nil until a live Keychain read has happened in this process.
    static var lastPlanFields: [String: String]? { planFieldsBox.get() }

    static func planFields(fromKeychainValue data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }
        var fields: [String: String] = [:]
        for key in ["subscriptionType", "rateLimitTier"] {
            if let value = oauth[key] as? String, !value.isEmpty, value.count < 64 { fields[key] = value }
        }
        return fields.isEmpty ? nil : fields
    }

    private static let planFieldsBox = PlanFieldsBox()
    private static let expiresBox = ExpiryBox()

    /// When the access token `resolve` last read expires (a time, never the
    /// token). Claude Code's token lives about 8 hours and only Claude Code
    /// renews it, so on a Mac where it hasn't run lately this is in the past.
    static var lastExpiresAt: Date? { expiresBox.get() }

    static func expiresAt(fromKeychainValue data: Data) -> Date? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let ms = jsonMillis(oauth["expiresAt"]), ms > 0
        else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func jsonMillis(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private final class ExpiryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date?
        func set(_ newValue: Date?) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Date? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class PlanFieldsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: String]?
        func set(_ newValue: [String: String]?) { lock.lock(); if let newValue { value = newValue }; lock.unlock() }
        func get() -> [String: String]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func accessToken(fromKeychainValue data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    static func liveAccount(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let account = env["BLOOM_CLAUDE_KEYCHAIN_ACCOUNT"], !account.isEmpty { return account }
        if let user = env["USER"], !user.isEmpty { return user }
        let name = NSUserName()
        return name.isEmpty ? nil : name
    }

    /// Runs `/usr/bin/security` with a timeout. Output is never logged.
    static func runLiveSecurity(_ arguments: [String], timeout: TimeInterval = ClaudeOfficialUsageAPI.keychainTimeout) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let box = DataBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            box.set(stdout.fileHandleForReading.readDataToEndOfFile())
            reader.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            _ = reader.wait(timeout: .now() + 1)
            return nil
        }
        _ = reader.wait(timeout: .now() + 1)
        return CommandResult(status: process.terminationStatus, stdout: box.get())
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}

// MARK: - Fetch outcome (port of fetch_api_usage)

enum ClaudeNativeFetchOutcome {
    case ok([String: Any])
    case rateLimited(retryAfter: String?)
    case unauthorized
    case offline(String)
}

enum ClaudeNativeHTTP {
    struct Response {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    typealias Transport = (URLRequest) -> Result<Response, Error>

    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: ClaudeOfficialUsageAPI.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: ClaudeOfficialUsageAPI.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ClaudeOfficialUsageAPI.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func classify(_ result: Result<Response, Error>) -> ClaudeNativeFetchOutcome {
        switch result {
        case .failure(let error):
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return .offline(detail.isEmpty ? String(describing: error) : detail)
        case .success(let response):
            switch response.statusCode {
            case 200..<300:
                break
            case 429:
                let retryAfter = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
                return .rateLimited(retryAfter: retryAfter)
            case 401, 403:
                return .unauthorized
            default:
                return .offline("HTTP \(response.statusCode)")
            }
            do {
                let object = try JSONSerialization.jsonObject(with: response.body)
                guard let body = object as? [String: Any] else {
                    return .offline("usage endpoint returned JSON that is not an object")
                }
                return .ok(body)
            } catch {
                return .offline("usage endpoint returned invalid JSON: \(error.localizedDescription)")
            }
        }
    }

    /// One GET on an ephemeral session: no cookies, no cache, no credential store.
    static func liveTransport(_ request: URLRequest) -> Result<Response, Error> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ClaudeOfficialUsageAPI.requestTimeout
        configuration.timeoutIntervalForResource = ClaudeOfficialUsageAPI.requestTimeout + 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.set(.failure(error))
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key)] = String(describing: value)
                }
                box.set(.success(Response(statusCode: http.statusCode, headers: headers, body: data ?? Data())))
            } else {
                box.set(.failure(URLError(.badServerResponse)))
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + ClaudeOfficialUsageAPI.requestTimeout + 10) == .timedOut {
            task.cancel()
            return .failure(URLError(.timedOut))
        }
        return box.get() ?? .failure(URLError(.unknown))
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Response, Error>?
        func set(_ newValue: Result<Response, Error>) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Result<Response, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

// MARK: - Throttle

enum ClaudeNativeThrottle {
    /// Nil when a fetch may run now; otherwise why it is skipped.
    static func skipReason(
        trigger: ClaudeNativeTrigger,
        now: Date,
        lastAttemptAt: Date?,
        lastStatus: String?,
        retryAt: Date?,
        sharedCooldownUntil: Date? = nil
    ) -> String? {
        let elapsed = lastAttemptAt.map { now.timeIntervalSince($0) }
        if let elapsed, elapsed >= 0, elapsed < ClaudeOfficialUsageAPI.manualFloor {
            return "last attempt \(Int(elapsed))s ago"
        }
        let status = lastStatus?.lowercased()
        switch trigger {
        case .scheduled:
            if let retryAt, retryAt > now {
                return "\(status ?? "cooldown") until \(ClaudeOfficialUsageParser.isoZms(retryAt))"
            }
            if let sharedCooldownUntil, sharedCooldownUntil > now {
                return "shared cooldown until \(ClaudeOfficialUsageParser.isoZms(sharedCooldownUntil))"
            }
            // An expired token is re-checked on its own short retry (no
            // network), so the renewed token is fetched at once.
            if status != "token_expired", let elapsed, elapsed >= 0, elapsed < ClaudeOfficialUsageAPI.scheduledInterval {
                return "last attempt \(Int(elapsed))s ago"
            }
        case .manual, .setup:
            // Refresh may retry a durable failure (the user may have just
            // signed in), but never inside the endpoint's own 429 window.
            if status == "rate_limited", let retryAt, retryAt > now {
                return "rate_limited until \(ClaudeOfficialUsageParser.isoZms(retryAt))"
            }
        }
        return nil
    }
}

// MARK: - Writer coexistence

enum ClaudeNativeCoexistence {
    static let writerLabel = "com.codexusagehud.claude-writer"
    /// Another producer wrote claude-usage.json this recently: stand down.
    static let activeProducerWindow: TimeInterval = 15 * 60

    enum Decision: Equatable {
        case run
        case standDown(String)
    }

    static func decide(
        isolatedStateDir: Bool,
        claudeConnected: Bool,
        setUpDone: Bool,
        writerInstalled: Bool,
        sharedFileModifiedAt: Date?,
        now: Date
    ) -> Decision {
        if isolatedStateDir { return .standDown("isolated state dir") }
        if !claudeConnected { return .standDown("Claude lane is off") }
        if !setUpDone { return .standDown("Set up has not run") }
        if writerInstalled { return .standDown("\(writerLabel) owns the Claude lane") }
        if let modified = sharedFileModifiedAt {
            let age = now.timeIntervalSince(modified)
            if age >= 0, age < activeProducerWindow {
                return .standDown("another producer updated claude-usage.json \(Int(age))s ago")
            }
        }
        return .run
    }

    static func liveDecision(now: Date = Date(), fileManager fm: FileManager = .default) -> Decision {
        let writerPlist = UsagePaths.launchdDirectory.appendingPathComponent("\(writerLabel).plist")
        let shared = UsagePaths.stateDirectory.appendingPathComponent("claude-usage.json")
        let modified = (try? fm.attributesOfItem(atPath: shared.path))?[.modificationDate] as? Date
        return decide(
            isolatedStateDir: UsagePaths.isIsolatedStateDir,
            claudeConnected: ProviderPreferences.isConnected("claude"),
            setUpDone: BackgroundRefreshService.isInstalled(fileManager: fm),
            writerInstalled: fm.fileExists(atPath: writerPlist.path),
            sharedFileModifiedAt: modified,
            now: now
        )
    }
}

// MARK: - Reader

struct ClaudeNativeUsageReader {
    var stateFile: URL
    var sharedCooldownFile: URL?
    var now: () -> Date
    var timeZone: TimeZone
    var credential: () -> String?
    var transport: ClaudeNativeHTTP.Transport
    /// Plan fields from the credential `credential` just read, saved beside
    /// the usage reading so the Plans setting can detect Pro / Max 5x / Max 20x.
    var planFields: () -> [String: String]? = { nil }
    /// Expiry of the credential `credential` just read; nil when unknown.
    var credentialExpiresAt: () -> Date? = { nil }
    /// While the token is expired, look at the Keychain again this often
    /// (no network); the first renewed token is fetched at once.
    static let expiredRecheck: TimeInterval = 60

    static func live(stateFile: URL = UsagePaths.stateDirectory.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)) -> ClaudeNativeUsageReader {
        ClaudeNativeUsageReader(
            stateFile: stateFile,
            sharedCooldownFile: UsagePaths.stateDirectory.appendingPathComponent(".claude-official-rate-limited-until"),
            now: Date.init,
            timeZone: .current,
            credential: {
                ClaudeNativeCredential.resolve(
                    env: ProcessInfo.processInfo.environment,
                    account: ClaudeNativeCredential.liveAccount(),
                    runSecurity: { ClaudeNativeCredential.runLiveSecurity($0) }
                )
            },
            transport: ClaudeNativeHTTP.liveTransport,
            planFields: { ClaudeNativeCredential.lastPlanFields },
            credentialExpiresAt: { ClaudeNativeCredential.lastExpiresAt }
        )
    }

    /// Runs one throttled fetch and writes the native snapshot. Blocking.
    @discardableResult
    func run(trigger: ClaudeNativeTrigger) -> ClaudeNativeRunReport {
        let previous = readPrevious()
        let status = previous?["officialUsageStatus"] as? [String: Any]
        let attemptAt = now()
        if let reason = ClaudeNativeThrottle.skipReason(
            trigger: trigger,
            now: attemptAt,
            lastAttemptAt: UsageInsights.parseDate(status?["updatedAt"] as? String),
            lastStatus: status?["status"] as? String,
            retryAt: UsageInsights.parseDate(status?["retryAt"] as? String),
            sharedCooldownUntil: sharedCooldownUntil()
        ) {
            return .skipped(reason)
        }
        let document = fetchDocument(previous: previous, attemptAt: attemptAt)
        write(document)
        let written = document["officialUsageStatus"] as? [String: Any]
        return .fetched(status: written?["status"] as? String ?? "unknown", message: written?["message"] as? String ?? "")
    }

    /// One unthrottled fetch, returned as the snapshot document it would
    /// write. Never touches the state file. Used by the run path and the
    /// live probe.
    func fetchDocument(previous: [String: Any]?, attemptAt: Date) -> [String: Any] {
        guard let token = credential() else {
            return failure(previous: previous, status: "no_credential",
                           message: "Claude Code isn't signed in on this Mac. Open Claude Code and sign in; this lane fills in by itself.",
                           attemptAt: attemptAt, retryAfter: ClaudeOfficialUsageAPI.failureCooldown)
        }
        // An expired token is never sent: it only earns 401s, and repeated
        // 401s earn hour-long 429s that outlast the renewal.
        if let expires = credentialExpiresAt(), expires <= attemptAt {
            return failure(previous: previous, status: "token_expired",
                           message: Self.tokenExpiredMessage,
                           attemptAt: attemptAt, retryAfter: Self.expiredRecheck)
        }
        let outcome = ClaudeNativeHTTP.classify(transport(ClaudeNativeHTTP.request(token: token)))
        switch outcome {
        case .rateLimited(let retryAfter):
            let seconds = retryAfter.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                ?? ClaudeOfficialUsageAPI.rateLimitCooldown
            return failure(previous: previous, status: "rate_limited",
                           message: "Claude usage endpoint is rate-limited; the last reading stays until the retry time.",
                           attemptAt: attemptAt, retryAfter: seconds)
        case .unauthorized:
            return failure(previous: previous, status: "unauthorized",
                           message: "Claude refused this sign-in. Open Claude Code and sign in again; this lane fills in by itself.",
                           attemptAt: attemptAt, retryAfter: ClaudeOfficialUsageAPI.failureCooldown)
        case .offline(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return failure(previous: previous, status: "offline",
                           message: trimmed.isEmpty ? "Usage endpoint unreachable." : "Usage endpoint unreachable: \(trimmed)",
                           attemptAt: attemptAt, retryAfter: ClaudeOfficialUsageAPI.failureCooldown,
                           detail: trimmed.isEmpty ? nil : trimmed)
        case .ok(let body):
            guard var payload = ClaudeOfficialUsageParser.buildPayload(body: body, capturedAt: attemptAt, timeZone: timeZone) else {
                return failure(previous: previous, status: "unparsed",
                               message: "No official Claude usage parsed from the API response.",
                               attemptAt: attemptAt, retryAfter: ClaudeOfficialUsageAPI.failureCooldown)
            }
            let iso = ClaudeOfficialUsageParser.isoZms(attemptAt)
            // Same per-window tag the Python merge adds to the windows it accepts.
            for key in ["currentSession", "week"] {
                if var window = payload[key] as? [String: Any] {
                    window["source"] = "official"
                    payload[key] = window
                }
            }
            payload["producer"] = ClaudeOfficialUsageAPI.producer
            if let plan = planFields() { payload["plan"] = plan }
            payload["officialUsageStatus"] = [
                "status": "ok",
                "message": "Claude Code official usage API parsed.",
                "updatedAt": iso,
                "exitCode": 0,
            ] as [String: Any]
            // A response is authoritative for the whole window set. When
            // Fable was on this account and is now missing, keep the row and
            // say "no reading since reset" (same literal the Python merge
            // writes); an account that never had Fable shows no Fable row.
            if payload["weekFable"] == nil, Self.previousHadFable(previous) {
                payload["rateLimitExpired"] = ["weekFable"]
                payload["rateLimitExpiredAt"] = iso
            }
            return payload
        }
    }

    static let tokenExpiredMessage = "Claude Code's sign-in on this Mac paused because Claude Code hasn't run here for a while. Open Claude Code once and this lane catches up by itself within a minute."

    static func previousHadFable(_ previous: [String: Any]?) -> Bool {
        guard let previous else { return false }
        if previous["weekFable"] is [String: Any] { return true }
        return (previous["rateLimitExpired"] as? [String])?.contains("weekFable") == true
    }

    private func failure(
        previous: [String: Any]?,
        status: String,
        message: String,
        attemptAt: Date,
        retryAfter: TimeInterval,
        detail: String? = nil
    ) -> [String: Any] {
        // Keep the last good windows and their own capture times; a failed
        // fetch never freshens an old reading.
        var document = previous ?? [
            "schemaVersion": 1,
            "provider": "claude",
            "displayName": "Claude Code",
            "source": ClaudeOfficialUsageAPI.source,
            "sourceKind": "official_api",
            "contributors": [Any](),
        ]
        let iso = ClaudeOfficialUsageParser.isoZms(attemptAt)
        var statusObject: [String: Any] = [
            "status": status,
            "message": message,
            "updatedAt": iso,
            "retryAt": ClaudeOfficialUsageParser.isoZms(attemptAt.addingTimeInterval(retryAfter)),
            "exitCode": 0,
        ]
        if let detail { statusObject["detail"] = detail }
        document["producer"] = ClaudeOfficialUsageAPI.producer
        document["officialUsageStatus"] = statusObject
        document["providerHealth"] = statusObject
        document["health"] = [
            "verdict": status == "rate_limited" ? "stale" : "degraded",
            "reason": message,
            "checkedAt": iso,
        ] as [String: Any]
        return document
    }

    private func readPrevious() -> [String: Any]? {
        guard let data = try? Data(contentsOf: stateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["provider"] as? String) == "claude"
        else { return nil }
        return object
    }

    private func sharedCooldownUntil() -> Date? {
        guard let sharedCooldownFile,
              let raw = try? String(contentsOf: sharedCooldownFile, encoding: .utf8),
              let epoch = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              epoch > 0
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    private func write(_ document: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(document),
              var data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        let fm = FileManager.default
        let directory = stateFile.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temp = directory.appendingPathComponent(".\(stateFile.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp.path, stateFile.path) != 0 {
            try? fm.removeItem(at: temp)
        }
    }
}

// MARK: - Scheduler

/// The reader's own timer, separate from UsageState's display refresh. Ticks
/// every 60 seconds on a utility queue; each tick is two file checks unless
/// the coexistence rule and the 10-minute throttle both allow a fetch.
final class ClaudeNativeUsageService: @unchecked Sendable {
    static let shared = ClaudeNativeUsageService()
    static let tickInterval: TimeInterval = 60

    private let queue = DispatchQueue(label: "com.codexusagehud.claude-native", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 5, repeating: Self.tickInterval, leeway: .seconds(10))
            source.setEventHandler { [weak self] in
                _ = self?.runOnQueue(.scheduled)
            }
            source.resume()
            timer = source
        }
    }

    /// Blocking; call from a background thread, never from the main thread.
    @discardableResult
    func run(trigger: ClaudeNativeTrigger) -> ClaudeNativeRunReport {
        queue.sync { runOnQueue(trigger) }
    }

    private func runOnQueue(_ trigger: ClaudeNativeTrigger) -> ClaudeNativeRunReport {
        if case .standDown(let reason) = ClaudeNativeCoexistence.liveDecision() {
            return .skipped(reason)
        }
        return ClaudeNativeUsageReader.live().run(trigger: trigger)
    }
}
