import AppKit
import CryptoKit
import Security
import Darwin
import UniformTypeIdentifiers
import SwiftUI

/// Sharing is opt-in. Only a small allowlisted projection leaves the Mac.
@MainActor
final class ReadmeBadge: ObservableObject {
    static let shared = ReadmeBadge()
    struct Configuration: Codable {
        var token = ""
        var enabled = false
        var revokePending = false
        var provider = "claude"
        var window = "week"
        var label = ""
        var style = "flat"
        var color = "pace"
        var showUsed = true
    }
    struct Payload: Encodable {
        let provider: String
        let window: String
        let label: String
        let style: String
        let color: String
        let showUsed: Bool
        let usedPct: Double?
        let capturedAt: String
        let resetAt: String?
        let confidence: String

        // Nulls are part of the server contract, including unavailable windows.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(provider, forKey: .provider); try c.encode(window, forKey: .window)
            try c.encode(label, forKey: .label); try c.encode(style, forKey: .style)
            try c.encode(color, forKey: .color); try c.encode(showUsed, forKey: .showUsed)
            try c.encode(usedPct, forKey: .usedPct); try c.encode(capturedAt, forKey: .capturedAt)
            try c.encode(resetAt, forKey: .resetAt); try c.encode(confidence, forKey: .confidence)
        }
        enum Keys: String, CodingKey { case provider, window, label, style, color, showUsed, usedPct, capturedAt, resetAt, confidence }
    }
    @Published var config: Configuration
    @Published private(set) var busy = false
    @Published private(set) var status = "Sharing is off."
    @Published private(set) var visits: Int?
    @Published private(set) var published = false
    private var lastAttempt = Date.distantPast
    private var file: URL { UsagePaths.stateDirectory.appendingPathComponent("readme-badge.json") }

    private init() {
        let path = UsagePaths.stateDirectory.appendingPathComponent("readme-badge.json")
        config = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        if config.enabled { status = "Waiting to sync with the badge service." }
        if config.revokePending { status = "Removal pending; retrying when connected." }
    }

    var id: String {
        SHA256.hash(data: Data(config.token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
    var base: String { "https://hud.thaliabloom.com/badges/\(id)" }
    var markdown: String { "[![Usage HUD](\(base)/badge.svg)](\(base)/visit)" }
    var html: String { "<a href=\"\(base)/visit\"><img alt=\"Usage HUD\" src=\"\(base)/badge.svg\"></a>" }

    func payload(_ snapshots: [UsageSnapshot]) -> Payload {
        let snapshot = snapshots.first { $0.provider == config.provider }
        let window = config.window == "week" ? snapshot?.week : snapshot?.currentSession
        let captured = window?.capturedAt ?? window?.eventAt ?? snapshot?.capturedAt ?? snapshot?.eventAt ?? snapshot?.updatedAt
        let observed = captured.flatMap(Self.date)
        let stamp = observed ?? Date()
        let reset = window?.resetAt.flatMap(Self.date)
        let healthy = snapshot?.health?.isWarning != true && snapshot?.providerHealth?.isWarning != true && snapshot?.officialUsageStatus?.isWarning != true
        let raw = window?.usedPct
        let valid = observed != nil && healthy && window?.isExpired != true && window?.isUnknown != true && Date().timeIntervalSince(stamp) <= 1800 && stamp <= Date().addingTimeInterval(60) && (reset == nil || reset! > Date())
        let pct = valid ? raw.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil } : nil
        let confidence = snapshot?.confidence ?? "unknown"
        return Payload(provider: config.provider, window: config.window,
                       label: String(config.label.prefix(24)), style: config.style, color: config.color,
                       showUsed: config.showUsed, usedPct: pct,
                       capturedAt: ISO8601DateFormatter().string(from: stamp),
                       resetAt: reset.map { ISO8601DateFormatter().string(from: $0) },
                       confidence: ["official", "high", "medium", "manual", "unknown"].contains(confidence) ? confidence : "unknown")
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: text) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    private func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: UsagePaths.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(config)
        // Create the temporary file with owner-only permissions before writing secrets.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".badge-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func setSharing(_ enabled: Bool, snapshots: [UsageSnapshot]) {
        guard !busy else { return }
        config.enabled = enabled
        config.revokePending = !enabled && !config.token.isEmpty
        if enabled && config.token.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                config.enabled = false; status = "Could not create a badge key."; return
            }
            config.token = bytes.map { String(format: "%02x", $0) }.joined()
        }
        do { try save() } catch {
            config.enabled = false; status = "Could not save badge settings; sharing paused."; return
        }
        published = false
        sync(snapshots, force: true)
    }

    func sync(_ snapshots: [UsageSnapshot], force: Bool = false) {
        guard !busy, config.enabled || config.revokePending,
              force || Date().timeIntervalSince(lastAttempt) >= 300 else { return }
        do { try save() } catch { status = "Could not save badge settings."; return }
        busy = true
        lastAttempt = Date()
        let revoke = config.revokePending
        let body = payload(snapshots)
        Task {
            defer { busy = false }
            do {
                _ = try await request("snapshot", method: revoke ? "DELETE" : "PUT", body: revoke ? nil : JSONEncoder().encode(body))
                if revoke {
                    config.revokePending = false
                    try save()
                    published = false
                    status = "Sharing is off; the published snapshot was removed."
                } else {
                    published = true
                    status = "Synced · \(Date().formatted(date: .omitted, time: .shortened)) · \(body.confidence) confidence"
                    do {
                        let data = try await request("stats", method: "GET")
                        visits = (try JSONSerialization.jsonObject(with: data) as? [String: Int])?["visits"]
                    } catch { status += " · visit count unavailable" }
                }
            } catch {
                status = revoke ? "Removal pending. The last badge stays public until Retry removal works." : "Couldn’t reach the badge service. Try Sync now in a minute."
            }
        }
    }

    func saveSVG() {
        guard published, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = "usage-hud-\(config.provider)-\(config.window).svg"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.busy = true
                defer { self.busy = false }
                do {
                    let data = try await self.request("badge.svg", method: "GET")
                    guard String(data: data, encoding: .utf8)?.hasPrefix("<svg ") == true else { throw URLError(.cannotDecodeContentData) }
                    try data.write(to: url, options: .atomic)
                    self.status = "Saved SVG. The saved file is a static copy."
                } catch { self.status = "Could not save SVG. Try again after syncing." }
            }
        }
    }

    private func request(_ action: String, method: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(base)/\(action)")!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

struct ReadmeBadgeSection: View {
    @ObservedObject var state: UsageState
    @ObservedObject private var badge = ReadmeBadge.shared
    @State private var format = "Markdown"
    @State private var copied = false
    @State private var customHex = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("README badge").font(.system(size: 15, weight: .semibold))
            Text("Share one usage window at hud.thaliabloom.com. Your public badge refreshes every five minutes while Usage HUD is running. Only its percentage, provider, window, times, confidence and appearance are sent. No account, prompts, paths or provider credentials.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Picker("Provider", selection: $badge.config.provider) {
                    Text("Claude").tag("claude"); Text("Codex").tag("codex"); Text("Gemini").tag("gemini")
                }
                Picker("Window", selection: $badge.config.window) {
                    Text("Week").tag("week"); Text("5-hour session").tag("session")
                }
            }
            TextField("Label (optional, 24 characters)", text: $badge.config.label)
                .onChange(of: badge.config.label) { _, value in badge.config.label = String(value.prefix(24)) }
            HStack {
                Picker("Style", selection: $badge.config.style) {
                    Text("Flat").tag("flat"); Text("Flat square").tag("flat-square")
                    Text("For the badge").tag("for-the-badge"); Text("Meter").tag("meter"); Text("HUD pill").tag("hud")
                }
                Picker("Color", selection: $badge.config.color) {
                    Text("By usage").tag("pace"); Text("Brand").tag("brand")
                    Text("Blue").tag("4285f4"); Text("Purple").tag("8957e5")
                    if !["pace", "brand", "4285f4", "8957e5"].contains(badge.config.color) { Text("Custom").tag(badge.config.color) }
                }
            }
            HStack {
                Text("Custom color")
                TextField("6-digit hex, e.g. d97757", text: $customHex)
                    .onChange(of: customHex) { _, value in
                        let hex = value.replacingOccurrences(of: "#", with: "")
                        if hex.count == 6 && hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) { badge.config.color = hex.lowercased() }
                    }
            }
            Toggle("Add “used” after the number", isOn: $badge.config.showUsed)
            preview
            Toggle("Publish my badge and keep it synced", isOn: Binding(get: { badge.config.enabled }, set: { badge.setSharing($0, snapshots: state.snapshots) }))
            HStack {
                Button(badge.config.revokePending ? "Retry removal" : "Sync now") { badge.sync(state.snapshots, force: true) }
                    .disabled(!badge.config.enabled && !badge.config.revokePending)
                if badge.busy { ProgressView().controlSize(.small) }
                Text(badge.status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if badge.config.enabled && badge.published {
                HStack {
                    Picker("Copy as", selection: $format) {
                        Text("Markdown").tag("Markdown"); Text("HTML").tag("HTML"); Text("Image URL").tag("Image URL")
                    }
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        copied = true
                    }
                }
                Button("Save SVG…") { badge.saveSVG() }
                Text(snippet).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Text("\(badge.visits.map(String.init) ?? "—") badge visits · clicks through to the badge page, including repeats and bots, not unique people.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("A reading older than 30 minutes shows as stale; a missing one shows as unavailable. GitHub can cache the image for a few minutes. Turning sharing off removes the public badge.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .disabled(badge.busy)
        .onChange(of: format) { _, _ in copied = false }
    }
    private var snippet: String { format == "Markdown" ? badge.markdown : format == "HTML" ? badge.html : "\(badge.base)/badge.svg" }
    private var preview: some View {
        let payload = badge.payload(state.snapshots)
        let label = payload.label.isEmpty ? "\(payload.provider.capitalized) \(payload.window)" : payload.label
        let value = payload.usedPct.map { "\(Int($0.rounded()))%\(payload.showUsed ? " used" : "")" } ?? "unavailable"
        let large = payload.style == "for-the-badge"
        let color = previewColor(payload)
        let radius: CGFloat = payload.style == "hud" ? 12 : ["flat-square", "for-the-badge"].contains(payload.style) ? 0 : 3
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                Text(large ? label.uppercased() : label)
                    .padding(.horizontal, 10).padding(.vertical, large ? 7 : 4).background(Color(white: 0.2)).foregroundStyle(.white)
                HStack(spacing: 6) {
                    if payload.style == "meter" {
                        ProgressView(value: payload.usedPct ?? 0, total: 100).frame(width: 42).tint(.white)
                    }
                    Text(large ? value.uppercased() : value)
                }
                .padding(.horizontal, 10).padding(.vertical, large ? 7 : 4).background(color).foregroundStyle(previewInk(color))
            }
            .font(.system(size: 11)).clipShape(RoundedRectangle(cornerRadius: radius))
            .accessibilityElement(children: .combine)
            Text("Local preview · \(payload.confidence) confidence" + (payload.resetAt.flatMap(ReadmeBadge.date).map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func previewColor(_ payload: ReadmeBadge.Payload) -> Color {
        guard let pct = payload.usedPct else { return Color(white: 0.43) }
        let hex: String
        if payload.color == "pace" { hex = pct < 50 ? "2ea043" : pct < 80 ? "d29922" : "da3633" }
        else if payload.color == "brand" { hex = ["claude": "d97757", "codex": "10a37f", "gemini": "4285f4"][payload.provider] ?? "6e7681" }
        else { hex = payload.color }
        let rgb = UInt32(hex, radix: 16) ?? 0x6e7681
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    private func previewInk(_ color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722 > 0.179 ? .black : .white
    }
}
