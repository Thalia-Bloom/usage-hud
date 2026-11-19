import AppKit

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private weak var panelController: UsagePanelController?
    private weak var state: UsageState?
    private let menuActions: AppMenuActions

    init(panelController: UsagePanelController, state: UsageState, menuActions: AppMenuActions) {
        self.panelController = panelController
        self.state = state
        self.menuActions = menuActions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(AppInfo.productName)
            button.setAccessibilityHelp("Shows how much of each AI tool's limit is used. Right-click for options.")
        }
        updateIcon(snapshots: [])
        panelController.onVisibilityChange = { [weak self] visible in
            self?.setHighlighted(visible)
        }
    }

    var item: NSStatusItem { statusItem }

    /// The status item's button in screen coordinates, or nil while the menu
    /// bar has not placed it yet.
    var buttonScreenRect: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.width > 0 ? rect : nil
    }

    func updateIcon(snapshots: [UsageSnapshot]) {
        guard let button = statusItem.button else { return }
        let budgets = state?.budgets ?? [:]
        let visible = presentationProviders(snapshots: snapshots, budgets: budgets)
        let readings = StatusItemText.readings(providers: visible, snapshots: snapshots, budgets: budgets)

        var lanes = readings.map(\.glyphLane)
        if lanes.isEmpty {
            lanes = ProviderCatalog.displayProviders.map { GlyphLane(name: $0.name, usedPct: nil, mode: "unknown") }
        }
        button.image = UsageStatusIcon.image(lanes: lanes)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = StatusItemText.tooltip(readings)
        button.setAccessibilityValue(StatusItemText.accessibilityValue(readings))
    }

    private func presentationProviders(snapshots: [UsageSnapshot], budgets: [String: BudgetState]) -> [String] {
        let visible = UsageInsights.visibleProviderOrder(snapshots: snapshots, budgets: budgets)
        let priority = ["claude", "codex", "gemini", "grok", "local"]
        return visible.sorted { (priority.firstIndex(of: $0) ?? 99) < (priority.firstIndex(of: $1) ?? 99) }
    }

    @objc private func handleClick(_ sender: Any?) {
        if let event = NSApp.currentEvent, StatusClick.opensMenu(type: event.type, modifiers: event.modifierFlags) {
            showMenu()
            return
        }
        panelController?.toggle(anchor: statusItem)
    }

    /// Right-click / control-click: the native status menu. The menu is
    /// attached only for this click so a plain left-click still opens the
    /// panel, and `performClick` lets AppKit place and highlight it exactly
    /// like a system menu-bar extra. Tracking is synchronous, so the menu is
    /// detached again as soon as it closes.
    private func showMenu() {
        panelController?.hide()
        statusItem.menu = AppMenu.statusMenu(actions: menuActions)
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Keep the menu-bar item highlighted while the panel is open, like a
    /// native menu. Deferred one turn so the button's own mouse-up
    /// un-highlight cannot land after it.
    private func setHighlighted(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.highlight(on)
        }
    }
}

enum StatusClick {
    /// Right-click, or control-click, opens the menu; any other click
    /// toggles the panel.
    static func opensMenu(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .rightMouseUp, .rightMouseDown:
            return true
        case .leftMouseUp, .leftMouseDown:
            return modifiers.contains(.control)
        default:
            return false
        }
    }
}

// MARK: - Plain-language status (tooltip + VoiceOver)

/// One lane as the menu-bar item describes it in words.
struct StatusLaneReading: Equatable {
    var name: String
    var weekUsed: Double?
    var sessionUsed: Double?
    /// Budget mode: green/yellow/orange/red/freeze, "unknown", or "local"
    /// for a count-only lane.
    var mode: String
    var tokensToday: Int? = nil
    var isConnected: Bool = false
    var isOld: Bool = false

    var glyphLane: GlyphLane {
        GlyphLane(name: name, usedPct: weekUsed ?? sessionUsed, mode: mode, isConnected: isConnected)
    }
}

/// Tooltip and VoiceOver text for the menu-bar item. Pure so every phrase is
/// testable. It never uses the internal GO/WATCH/SLOW/STOP/FREEZE words.
enum StatusItemText {
    static func readings(providers: [String], snapshots: [UsageSnapshot], budgets: [String: BudgetState], now: Date = Date()) -> [StatusLaneReading] {
        var readings: [StatusLaneReading] = []
        for provider in providers {
            let snap = snapshots.first { $0.provider.lowercased() == provider }
            let week = snap?.week?.usedPct
            let session = snap?.currentSession?.usedPct
            let isOld = UsageInsights.laneFreshness(for: snap, now: now).isOld
            let mode: String
            if provider == "local" {
                mode = "local"
            } else {
                mode = budgets[provider]?.mode
                    ?? (week ?? session).map { BudgetEvaluator.fallbackModeFromHeadroom(max(0, 100 - $0)) }
                    ?? "unknown"
            }
            readings.append(StatusLaneReading(
                name: UsageInsights.label(for: provider),
                weekUsed: week,
                sessionUsed: session,
                mode: mode,
                tokensToday: provider == "local" ? snap?.session?.todayTotal : nil,
                isConnected: snap != nil,
                isOld: isOld
            ))
            // Fable has its own weekly limit inside the Claude plan, so it
            // gets its own bar right after Claude.
            if provider == "claude", let fable = snap?.weekFable?.usedPct {
                readings.append(StatusLaneReading(
                    name: "Fable",
                    weekUsed: fable,
                    sessionUsed: nil,
                    mode: BudgetEvaluator.fallbackModeFromHeadroom(max(0, 100 - fable)),
                    isConnected: true,
                    isOld: isOld
                ))
            }
        }
        return readings
    }

    /// Plain words for a budget mode; nil when nothing needs saying.
    static func plainStatus(_ mode: String) -> String? {
        switch mode.lowercased() {
        case "yellow": return "running hot"
        case "orange": return "running low"
        case "red": return "nearly out"
        case "freeze": return "spent until reset"
        default: return nil
        }
    }

    static func laneSummary(_ reading: StatusLaneReading, separator: String = " \u{00B7} ") -> String {
        if let tokens = reading.tokensToday, reading.weekUsed == nil, reading.sessionUsed == nil {
            return "\(reading.name) \(compactTokens(tokens)) tokens today"
        }
        var parts: [String]
        if let week = reading.weekUsed {
            parts = ["\(reading.name) \(percent(week)) of week"]
            // Name the 5-hour window when it, not the week, is the pressure.
            if let session = reading.sessionUsed, session >= 60 {
                parts.append("5-hour \(percent(session))")
            }
        } else if let session = reading.sessionUsed {
            parts = ["\(reading.name) \(percent(session)) of 5-hour window"]
        } else {
            return "\(reading.name) no reading yet"
        }
        if reading.isOld {
            parts.append("old reading")
        } else if let status = plainStatus(reading.mode) {
            parts.append(status)
        }
        return parts.joined(separator: separator)
    }

    static func tooltip(_ readings: [StatusLaneReading]) -> String {
        var lines = [AppInfo.productName]
        if readings.isEmpty {
            lines.append("No tools shown yet. Open Settings to choose them.")
        } else {
            lines += readings.map { laneSummary($0) }
        }
        lines.append("Click for details. Right-click for options.")
        return lines.joined(separator: "\n")
    }

    static func accessibilityValue(_ readings: [StatusLaneReading]) -> String {
        guard !readings.isEmpty else { return "No tools shown yet" }
        return readings.map { laneSummary($0, separator: ", ") }.joined(separator: "; ")
    }

    /// Whole percent. Never rounds a nearly spent lane up to a false 100%,
    /// or a barely started one down to 0%.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let clamped = max(0, value)
        if clamped > 0 && clamped < 1 { return "<1%" }
        var whole = clamped.rounded()
        if whole >= 100 && clamped < 100 { whole = 99 }
        return "\(Int(whole))%"
    }

    static func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

// MARK: - Menu-bar glyph

/// One menu-bar bar: a lane's weekly used % and budget mode. The name is
/// never drawn; the tooltip and VoiceOver carry it.
struct GlyphLane: Equatable {
    var name: String
    var usedPct: Double?   // nil = no reading
    var mode: String       // green/yellow/orange/red/freeze/unknown/local
    var isConnected = false
}

/// The menu-bar glyph: one slim bar per lane, filled from the bottom by the
/// share of its limit used. While every lane is calm it is a monochrome
/// template image, so the system tints it like its own icons (light and dark
/// bars, inactive displays, the highlight while the panel is open). Only a
/// lane that needs attention adds color, and only on that lane's fill.
enum UsageStatusIcon {
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2
    static let trackHeight: CGFloat = 12
    static let imageHeight: CGFloat = 18
    static let sidePad: CGFloat = 1
    static let cornerRadius: CGFloat = 1

    static func needsAttention(_ mode: String) -> Bool {
        ["yellow", "orange", "red", "freeze"].contains(mode.lowercased())
    }

    /// True when every lane is calm, so the glyph can be a template image.
    static func isTemplate(lanes: [GlyphLane]) -> Bool {
        !lanes.contains { $0.usedPct != nil && needsAttention($0.mode) }
    }

    static func width(laneCount: Int) -> CGFloat {
        let n = CGFloat(max(1, laneCount))
        return sidePad * 2 + n * barWidth + (n - 1) * barGap
    }

    /// Fill height snapped to device pixels. A known reading always shows at
    /// least one device pixel, so "0% used" differs from "no reading", and
    /// nothing pads small values up (the old pill minimum made 0–39% look
    /// the same).
    static func fillHeight(usedPct: Double, pixelsPerPoint: CGFloat) -> CGFloat {
        let scale = max(1, pixelsPerPoint)
        let fraction = CGFloat(max(0, min(1, usedPct.isFinite ? usedPct / 100 : 0)))
        let snapped = (trackHeight * fraction * scale).rounded() / scale
        return min(trackHeight, max(1 / scale, snapped))
    }

    static func image(lanes: [GlyphLane]) -> NSImage {
        let template = isTemplate(lanes: lanes)
        let size = NSSize(width: width(laneCount: lanes.count), height: imageHeight)

        // Drawn on demand, not baked: labelColor and the attention colors
        // resolve in the menu bar's own appearance every time it draws.
        let image = NSImage(size: size, flipped: false) { _ in
            let pixelsPerPoint = NSGraphicsContext.current.map { abs($0.cgContext.userSpaceToDeviceSpaceTransform.a) } ?? 2
            let ink: NSColor = template ? .black : .labelColor
            let trackY = ((imageHeight - trackHeight) / 2).rounded(.down)

            for (index, lane) in lanes.enumerated() {
                let x = sidePad + CGFloat(index) * (barWidth + barGap)
                let track = NSRect(x: x, y: trackY, width: barWidth, height: trackHeight)
                let trackPath = NSBezierPath(roundedRect: track, xRadius: cornerRadius, yRadius: cornerRadius)
                let hasSignal = lane.usedPct != nil || lane.isConnected
                ink.withAlphaComponent(hasSignal ? 0.24 : 0.11).setFill()
                trackPath.fill()

                guard let used = lane.usedPct else { continue }
                let fill = NSRect(x: x, y: trackY, width: barWidth, height: fillHeight(usedPct: used, pixelsPerPoint: pixelsPerPoint))
                NSGraphicsContext.saveGraphicsState()
                trackPath.addClip()
                let color = !template && needsAttention(lane.mode) ? modeColor(lane.mode) : ink
                color.setFill()
                NSBezierPath(rect: fill).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    /// Fill color for a lane that needs attention. Each has a deeper shade
    /// for light menu bars so amber and orange keep contrast on white.
    static func modeColor(_ mode: String) -> NSColor {
        switch mode.lowercased() {
        case "yellow": return dynamic(light: (0.80, 0.55, 0.00), dark: (1.00, 0.80, 0.24))
        case "orange": return dynamic(light: (0.90, 0.40, 0.04), dark: (1.00, 0.60, 0.26))
        case "red":    return dynamic(light: (0.84, 0.16, 0.15), dark: (1.00, 0.42, 0.40))
        case "freeze": return dynamic(light: (0.46, 0.34, 0.92), dark: (0.72, 0.62, 1.00))
        default:       return .labelColor
        }
    }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}

struct BudgetDriverAlert: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let label: String
    let percent: Double
    let severity: String
    let rule: String?
    let note: String?
}

struct BudgetState: Sendable {
    let mode: String
    let modeLabel: String
    let weeklyUsedPct: Double?
    let weeklyResetLabel: String?
    let currentSessionUsedPct: Double?
    let allowedWork: [String]
    let subagentPolicy: String?
    let driverAlerts: [BudgetDriverAlert]
    let updatedAt: String?
}

enum BudgetStateReader {
    static func load(provider: String = "claude") -> BudgetState? {
        var obj: [String: Any]?
        for url in UsagePaths.budgetStateCandidates(provider: provider) {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  decoded["mode"] is String
            else { continue }
            obj = decoded
            break
        }
        guard let obj, let mode = obj["mode"] as? String else { return nil }

        let alerts: [BudgetDriverAlert] = (obj["driverAlerts"] as? [[String: Any]] ?? []).map { d in
            BudgetDriverAlert(
                name: (d["name"] as? String) ?? "",
                label: (d["label"] as? String) ?? "",
                percent: jsonDouble(d["percent"]) ?? 0,
                severity: (d["severity"] as? String) ?? "yellow",
                rule: d["rule"] as? String,
                note: d["note"] as? String
            )
        }

        return BudgetState(
            mode: mode,
            modeLabel: (obj["modeLabel"] as? String) ?? mode,
            weeklyUsedPct: jsonDouble(obj["weeklyUsedPct"]),
            weeklyResetLabel: obj["weeklyResetLabel"] as? String,
            currentSessionUsedPct: jsonDouble(obj["currentSessionUsedPct"]),
            allowedWork: (obj["allowedWork"] as? [String]) ?? [],
            subagentPolicy: obj["subagentPolicy"] as? String,
            driverAlerts: alerts,
            updatedAt: obj["updatedAt"] as? String
        )
    }
}

private func jsonDouble(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
}

// Evaluates a UsageSnapshot against the shared policy file and writes a
// per-provider state file so notifications + the panel can read it.
enum BudgetEvaluator {
    static func evaluateAndPersist(snapshot: UsageSnapshot) {
        guard let policy = loadPolicy() else { return }
        let weekly = snapshot.week?.usedPct
        let session = snapshot.currentSession?.usedPct
        let mode = computeMode(weekly: weekly, session: session, policy: policy)
        let workflow = (policy["workflowModes"] as? [String: Any])?[mode] as? [String: Any] ?? [:]
        let alerts = driverAlerts(snapshot: snapshot, policy: policy)

        var payload: [String: Any] = [
            "schemaVersion": 1,
            "provider": snapshot.provider,
            "displayName": snapshot.displayName ?? snapshot.provider.capitalized,
            "mode": mode,
            "modeLabel": workflow["label"] as? String ?? mode,
            "subagentPolicy": workflow["subagentPolicy"] as? String ?? "",
            "allowedWork": workflow["allowedWork"] as? [String] ?? [],
            "weeklyResetLabel": snapshot.week?.resetLabel ?? "",
            "currentSessionResetLabel": snapshot.currentSession?.resetLabel ?? "",
            "driverAlerts": alerts,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let weekly {
            payload["weeklyUsedPct"] = weekly
        }
        if let session {
            payload["currentSessionUsedPct"] = session
        }
        payload["sourceUpdatedAt"] = snapshot.capturedAt ?? snapshot.updatedAt ?? ""
        payload["sourceEventAt"] = snapshot.eventAt ?? snapshot.updatedAt ?? ""

        let provider = snapshot.provider.lowercased()
        UsagePaths.ensureStateDirectory()
        let outURL = UsagePaths.budgetStateURL(provider: provider)
        guard shouldRewrite(payload, at: outURL) else { return }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outURL.path)
        }
    }

    /// The panel re-evaluates every 5 seconds; rewriting an unchanged file
    /// each time cost about 17,000 writes a day per lane. Write when anything
    /// but the stamp changed; otherwise refresh the stamp once a minute so
    /// readers that print its age (the doctor) still see it current.
    static func shouldRewrite(_ payload: [String: Any], at url: URL, now: Date = Date()) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stampText = existing.removeValue(forKey: "updatedAt") as? String,
              let stamp = ISO8601DateFormatter().date(from: stampText),
              now.timeIntervalSince(stamp) < 60 else { return true }
        var next = payload
        next.removeValue(forKey: "updatedAt")
        return !NSDictionary(dictionary: existing).isEqual(to: next)
    }

    private static func loadPolicy() -> [String: Any]? {
        for url in UsagePaths.policyCandidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return obj
        }
        return defaultPolicy
    }

    private static let defaultPolicy: [String: Any] = [
        "budgets": [
            "weeklyPct": ["greenMax": 60, "yellowMax": 80, "orangeMax": 90, "redMax": 99, "freezeAt": 100],
            // The 5h window is a pace gauge under the 100%-utilization policy: no
            // green ceiling, yellow starts above yellowMax. (A dead greenMax 35 was
            // removed 2026-09-03; computeMode never read it.)
            "currentSessionPct": ["yellowMax": 60, "orangeMax": 80, "redMax": 95]
        ],
        "workflowModes": [
            "green": ["label": "Normal build mode", "allowedWork": ["planned implementation", "short research", "backend hardening"], "subagentPolicy": "Allowed for bounded, disjoint work."],
            "yellow": ["label": "Conserve mode", "allowedWork": ["small implementation", "security fixes", "handoff cleanup"], "subagentPolicy": "Use only when it prevents a blocker."],
            "orange": ["label": "Critical conserve mode", "allowedWork": ["client blockers", "security issues", "short status updates"], "subagentPolicy": "Avoid unless urgent."],
            "red": ["label": "Triage-only mode", "allowedWork": ["production incidents", "security incidents", "critical blockers"], "subagentPolicy": "Do not spawn without explicit approval."],
            "freeze": ["label": "Token freeze", "allowedWork": ["security incidents", "production outages", "lightweight planning"], "subagentPolicy": "No subagents."]
        ]
    ]

    static func fallbackModeFromHeadroom(_ headroom: Double) -> String {
        weeklyMode(
            usedPct: max(0, min(100, 100 - headroom)),
            thresholds: defaultWeeklyThresholds
        )
    }

    private static var defaultWeeklyThresholds: [String: Any] {
        let budgets = defaultPolicy["budgets"] as? [String: Any] ?? [:]
        return budgets["weeklyPct"] as? [String: Any] ?? [:]
    }

    private static func computeMode(weekly: Double?, session: Double?, policy: [String: Any]) -> String {
        if weekly == nil && session == nil { return "unknown" }

        let budgets = policy["budgets"] as? [String: Any] ?? [:]
        let w = budgets["weeklyPct"] as? [String: Any] ?? [:]
        let s = budgets["currentSessionPct"] as? [String: Any] ?? [:]

        // Grade each window independently and take the worse one — a maxed
        // session must not be masked by a milder weekly band (e.g. weekly 81
        // "orange" hiding session 100 "red").
        var weeklyMode = "green"
        if let weekly {
            weeklyMode = self.weeklyMode(usedPct: weekly, thresholds: w)
        }
        var sessionMode = "green"
        if let session {
            if session > number(s["redMax"], fallback: 95) { sessionMode = "red" }
            else if session > number(s["orangeMax"], fallback: 80) { sessionMode = "orange" }
            else if session > number(s["yellowMax"], fallback: 60) { sessionMode = "yellow" }
        }
        let rank: [String: Int] = ["green": 0, "yellow": 1, "orange": 2, "red": 3, "freeze": 4]
        return (rank[weeklyMode] ?? 0) >= (rank[sessionMode] ?? 0) ? weeklyMode : sessionMode
    }

    private static func weeklyMode(usedPct: Double, thresholds: [String: Any]) -> String {
        if usedPct >= number(thresholds["freezeAt"], fallback: 100) { return "freeze" }
        if usedPct > number(thresholds["redMax"], fallback: 99) { return "freeze" }
        if usedPct > number(thresholds["orangeMax"], fallback: 90) { return "red" }
        if usedPct > number(thresholds["yellowMax"], fallback: 80) { return "orange" }
        if usedPct > number(thresholds["greenMax"], fallback: 60) { return "yellow" }
        return "green"
    }

    private static func driverAlerts(snapshot: UsageSnapshot, policy: [String: Any]) -> [[String: Any]] {
        let rules = policy["driverRules"] as? [String: Any] ?? [:]
        var alerts: [[String: Any]] = []

        for item in snapshot.contributors {
            let lowered = item.label.lowercased()
            for (name, rawRule) in rules {
                guard let rule = rawRule as? [String: Any] else { continue }
                let needle = (rule["triggerLabelContains"] as? String ?? "").lowercased()
                guard !needle.isEmpty, lowered.contains(needle) else { continue }

                let yellowAt = number(rule["yellowAtPercent"], fallback: 999)
                let orangeAt = number(rule["orangeAtPercent"], fallback: 999)
                let severity: String?
                if item.percent >= orangeAt {
                    severity = "orange"
                } else if item.percent >= yellowAt {
                    severity = "yellow"
                } else {
                    severity = nil
                }
                guard let severity else { continue }

                var alert: [String: Any] = [
                    "name": name,
                    "label": item.label,
                    "percent": item.percent,
                    "severity": severity,
                    "rule": rule["rule"] as? String ?? ""
                ]
                if let note = item.note { alert["note"] = note }
                alerts.append(alert)
            }
        }

        return alerts
    }

    private static func number(_ value: Any?, fallback: Double) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return fallback
    }
}

enum BudgetOverride {
    static func setUntil(_ date: Date) {
        UsagePaths.ensureStateDirectory()
        try? ISO8601DateFormatter().string(from: date).write(to: UsagePaths.overrideURL, atomically: true, encoding: .utf8)
    }

    static func clear() {
        for url in UsagePaths.overrideCandidates {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func activeUntil() -> Date? {
        for url in UsagePaths.overrideCandidates {
            guard let s = try? String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines),
                  let d = ISO8601DateFormatter().date(from: s),
                  d > Date()
            else { continue }
            return d
        }
        return nil
    }
}
