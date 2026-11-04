import Foundation

/// A minimal, read-only Model Context Protocol server over stdio.
///
/// Framing: one JSON-RPC 2.0 message per line on stdin, one response per
/// line on stdout, nothing else on stdout. Exits on EOF.
///
/// Dual-era (MCP 2026-07-28 "Versioning and Compatibility"):
/// - A request carrying `_meta["io.modelcontextprotocol/protocolVersion"]`
///   is served statelessly as a modern (2026-07-28) request: results carry
///   `resultType`, `_meta` serverInfo, and caching hints where required;
///   `server/discover` is implemented.
/// - An `initialize` request selects legacy semantics for this process,
///   negotiated per the 2025-11-25 lifecycle: echo the client's version when
///   supported, otherwise answer with the newest legacy version.
///
/// Tools only read the state files the app reads; nothing is written.
final class MCPServer {
    static let modernVersions = ["2026-07-28"]
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var supportedVersions: [String] { modernVersions + legacyVersions }

    static let serverName = "usage-hud"
    static let serverTitle = "Usage HUD"

    static let instructions = """
    Read-only usage limits for the AI coding plans on this Mac (Claude, Codex, Gemini, Grok, local models), \
    from the Usage HUD menu-bar app. Call which_plan_has_room before long, expensive or parallel work. \
    If your plan is running hot or nearly out, tell the user and name the plan with room. \
    Check each lane's stale flag and readingAgeSeconds before trusting a number.
    """

    private let summaryProvider: () -> AgentSummary
    private let version: String
    /// Version negotiated by `initialize`; legacy requests default to the newest legacy version.
    private(set) var negotiatedLegacyVersion: String?

    init(version: String = AppInfo.resolvedMarketingVersion,
         summaryProvider: @escaping () -> AgentSummary = { AgentSummaryLoader.load() }) {
        self.version = version
        self.summaryProvider = summaryProvider
    }

    private var serverInfo: [String: Any] {
        ["name": Self.serverName, "title": Self.serverTitle, "version": version]
    }

    // MARK: Transport

    /// Serve until `readLine` returns nil (stdin EOF).
    func run(readLine: () -> String?, write: (String) -> Void) {
        while let line = readLine() {
            if let response = handle(line: line) {
                write(response)
            }
        }
    }

    /// Serve the process's stdin/stdout. Returns when stdin closes.
    static func serveStandardIO() -> Int32 {
        let server = MCPServer()
        let out = FileHandle.standardOutput
        server.run(
            readLine: { Swift.readLine(strippingNewline: true) },
            write: { out.write(Data(($0 + "\n").utf8)) }
        )
        return 0
    }

    /// One line in, at most one line out (nil for notifications and blanks).
    func handle(line raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return encode(Self.errorResponse(id: NSNull(), code: -32700, message: "Parse error: each line must be one JSON-RPC message."))
        }
        if let batch = message as? [Any] {
            // Batches were allowed in 2025-03-26 only; answer them anyway.
            guard !batch.isEmpty else {
                return encode(Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid Request: empty batch."))
            }
            let responses = batch.compactMap { handle(message: $0) }
            return responses.isEmpty ? nil : encode(responses)
        }
        return handle(message: message).flatMap { encode($0) }
    }

    private func encode(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: response was not encodable."}}"#
        }
        // JSONSerialization escapes control characters inside strings, so a
        // serialized message never contains a raw newline.
        return text
    }

    // MARK: Dispatch

    func handle(message: Any) -> [String: Any]? {
        guard let request = message as? [String: Any] else {
            return Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid Request: expected a JSON object.")
        }
        let id = request["id"]
        guard let method = request["method"] as? String else {
            // A response or junk from the client: never answer a response.
            if request["result"] != nil || request["error"] != nil { return nil }
            return Self.errorResponse(id: id ?? NSNull(), code: -32600, message: "Invalid Request: missing method.")
        }
        // Notifications (no id) never get a reply.
        guard let id else { return nil }

        let params = request["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let requestedModern = meta["io.modelcontextprotocol/protocolVersion"] as? String

        if method == "initialize" {
            return initialize(id: id, params: params)
        }

        if let requestedModern, !Self.legacyVersions.contains(requestedModern) {
            guard Self.modernVersions.contains(requestedModern) else {
                return Self.errorResponse(id: id, code: -32022, message: "Unsupported protocol version",
                                          data: ["supported": Self.supportedVersions, "requested": requestedModern])
            }
            guard meta["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
                return Self.errorResponse(id: id, code: -32602,
                                          message: "Invalid params: _meta is missing io.modelcontextprotocol/clientCapabilities.")
            }
            return dispatch(id: id, method: method, params: params, era: .modern)
        }
        if method == "server/discover" {
            return Self.errorResponse(id: id, code: -32602,
                                      message: "Invalid params: _meta is missing io.modelcontextprotocol/protocolVersion. Supported versions: \(Self.supportedVersions.joined(separator: ", ")).")
        }
        let legacy = requestedModern ?? negotiatedLegacyVersion ?? Self.legacyVersions[0]
        return dispatch(id: id, method: method, params: params, era: .legacy(legacy))
    }

    enum Era: Equatable {
        case modern
        case legacy(String)

        /// structuredContent and outputSchema arrived in 2025-06-18.
        var supportsStructuredContent: Bool {
            switch self {
            case .modern: return true
            case .legacy(let version): return version >= "2025-06-18"
            }
        }
    }

    private func initialize(id: Any, params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let chosen = requested.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
        negotiatedLegacyVersion = chosen
        return [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "protocolVersion": chosen,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": serverInfo,
                "instructions": Self.instructions,
            ] as [String: Any],
        ]
    }

    private func dispatch(id: Any, method: String, params: [String: Any], era: Era) -> [String: Any] {
        switch method {
        case "server/discover":
            return result(id: id, era: era, [
                "supportedVersions": Self.supportedVersions,
                "capabilities": ["tools": [String: Any]()],
                "instructions": Self.instructions,
                "ttlMs": 3_600_000,
                "cacheScope": "public",
            ])
        case "ping":
            if era == .modern {
                return Self.errorResponse(id: id, code: -32601, message: "Method not found: ping (removed in 2026-07-28).")
            }
            return result(id: id, era: era, [:])
        case "tools/list":
            var body: [String: Any] = ["tools": Self.toolDefinitions(includeOutputSchema: era.supportsStructuredContent)]
            if era == .modern {
                body["ttlMs"] = 3_600_000
                body["cacheScope"] = "public"
            }
            return result(id: id, era: era, body)
        case "tools/call":
            return callTool(id: id, params: params, era: era)
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func result(id: Any, era: Era, _ body: [String: Any]) -> [String: Any] {
        var body = body
        if era == .modern {
            body["resultType"] = "complete"
            var meta = body["_meta"] as? [String: Any] ?? [:]
            meta["io.modelcontextprotocol/serverInfo"] = serverInfo
            body["_meta"] = meta
        }
        return ["jsonrpc": "2.0", "id": id, "result": body]
    }

    static func errorResponse(id: Any, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }

    // MARK: Tools

    static let toolNames = ["usage_status", "which_plan_has_room", "lane_detail", "spend_summary", "recent_activity"]

    private static let readOnlyAnnotations: [String: Any] = [
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
    ]

    static func toolDefinitions(includeOutputSchema: Bool) -> [[String: Any]] {
        let noArguments: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        var tools: [[String: Any]] = [
            [
                "name": "usage_status",
                "title": "Usage HUD: every plan",
                "description": """
                Usage limits for every AI coding plan on this Mac (Claude, Codex, Gemini, Grok, local models): \
                percent used, pace against the clock, reset time, forecast empty time when running hot, \
                confidence, and how old each reading is. Call before starting long or parallel work, before \
                spawning subagents, or when the user asks about limits. A lane with stale=true is an old \
                reading: say so instead of treating it as current. Read-only.
                """,
                "inputSchema": noArguments,
                "annotations": readOnlyAnnotations.merging(["title": "Usage HUD: every plan"]) { a, _ in a },
                "outputSchema": AgentSchema.summary,
            ],
            [
                "name": "which_plan_has_room",
                "title": "Usage HUD: which plan has room",
                "description": """
                Answers "which plan should this work go to right now?" in one call: the verdict for the \
                user's main plan (GO, WATCH, STOP, or CHECK when the reading is too old), the plan with the \
                most room right now (or null), and one sentence of advice. Call before long, expensive or \
                parallel work. If the verdict is WATCH or STOP, tell the user and name the plan with room \
                rather than silently continuing. Read-only.
                """,
                "inputSchema": noArguments,
                "annotations": readOnlyAnnotations.merging(["title": "Usage HUD: which plan has room"]) { a, _ in a },
                "outputSchema": AgentSchema.roomAdvice,
            ],
            [
                "name": "lane_detail",
                "title": "Usage HUD: one plan in detail",
                "description": """
                Every window (5-hour, weekly, daily, model-scoped week) for one plan: percent used, pace, \
                reset times, forecast, confidence and reading age. Use when you need one plan's full numbers \
                after usage_status or which_plan_has_room. Read-only.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "provider": [
                            "type": "string",
                            "description": "Plan to read: claude, codex, gemini, grok, or local. Display names such as \"Claude Code\" also work.",
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["provider"],
                    "additionalProperties": false,
                ] as [String: Any],
                "annotations": readOnlyAnnotations.merging(["title": "Usage HUD: one plan in detail"]) { a, _ in a },
                "outputSchema": AgentSchema.laneDetail,
            ],
            [
                "name": "spend_summary",
                "title": "Usage HUD: API value and plan cost",
                "description": """
                What the user's AI coding costs, two ways, per plan and in total: API value (what this \
                usage would cost at pay-per-use API prices, from local session logs; never billed) and the \
                plan price the user pays per month, plus the value multiple. Use when the user asks what \
                their usage costs, whether a plan is worth it, or which tool is cheapest to use. Always say \
                API value is not billed. Read-only.
                """,
                "inputSchema": noArguments,
                "annotations": readOnlyAnnotations.merging(["title": "Usage HUD: API value and plan cost"]) { a, _ in a },
            ],
            [
                "name": "recent_activity",
                "title": "Usage HUD: recent agent sessions",
                "description": """
                Coding-agent sessions active today and in the last 5 hours across Claude Code, Codex and \
                Gemini: tool, project folder name, model, last active time, tokens, API value and burn rate, \
                plus the top burner right now. Use when the user asks what is eating their limit. Contains \
                no prompts, file contents or paths. Read-only.
                """,
                "inputSchema": noArguments,
                "annotations": readOnlyAnnotations.merging(["title": "Usage HUD: recent agent sessions"]) { a, _ in a },
            ],
        ]
        if !includeOutputSchema {
            for i in tools.indices { tools[i].removeValue(forKey: "outputSchema") }
        }
        return tools
    }

    private func callTool(id: Any, params: [String: Any], era: Era) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return Self.errorResponse(id: id, code: -32602, message: "Invalid params: tools/call needs a tool name.")
        }
        guard Self.toolNames.contains(name) else {
            return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let summary = summaryProvider()

        switch name {
        case "usage_status":
            return toolResult(id: id, era: era, text: AgentText.status(summary), structured: Self.jsonObject(summary))
        case "which_plan_has_room":
            let advice = AgentRoomAdvice(summary: summary)
            return toolResult(id: id, era: era, text: advice.advice, structured: Self.jsonObject(advice))
        case "spend_summary":
            let spend = AgentSpend.current().spend
            return toolResult(id: id, era: era, text: AgentSpend.spendText(spend), structured: AgentSpend.jsonObject(spend))
        case "recent_activity":
            let activity = AgentSpend.current().activity
            return toolResult(id: id, era: era, text: AgentSpend.activityText(activity), structured: AgentSpend.jsonObject(activity))
        default:
            guard let requested = arguments["provider"] as? String, !requested.trimmingCharacters(in: .whitespaces).isEmpty else {
                return toolResult(id: id, era: era, text: "lane_detail needs a provider, for example {\"provider\": \"claude\"}.",
                                  structured: nil, isError: true)
            }
            switch AgentText.resolveProvider(requested, in: summary) {
            case .found(let lane):
                return toolResult(id: id, era: era, text: AgentText.laneDetail(lane),
                                  structured: ["lane": Self.jsonObject(lane) ?? [:]])
            case .notTracked(let providerName):
                return toolResult(id: id, era: era,
                                  text: "Usage HUD is not tracking \(providerName) on this Mac (it is turned off in Settings or not installed). Tracked: \(summary.lanes.map(\.provider).joined(separator: ", ")).",
                                  structured: nil, isError: true)
            case .unknown:
                return toolResult(id: id, era: era,
                                  text: "Unknown provider \"\(requested)\". Use one of: \(ProviderCatalog.ids.joined(separator: ", ")).",
                                  structured: nil, isError: true)
            }
        }
    }

    private func toolResult(id: Any, era: Era, text: String, structured: [String: Any]?, isError: Bool = false) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        var body: [String: Any] = ["isError": isError]
        if let structured {
            // Back-compat: the serialized JSON also travels as text.
            if let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) {
                content.append(["type": "text", "text": json])
            }
            if era.supportsStructuredContent { body["structuredContent"] = structured }
        }
        body["content"] = content
        return result(id: id, era: era, body)
    }

    static func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
