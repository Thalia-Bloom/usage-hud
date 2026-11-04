import AppKit
import SwiftUI

// ============================================================================
//  Usage HUD — verdict-first panel
//  Redesign 2026-06-01 (Apollo): opens to ONE answer ("can I afford heavy work
//  right now?") instead of a tab bar of equal-weight sections. Hero = the
//  binding-constraint headroom + operating mode; trio = 3 providers at a glance;
//  everything the old panel showed lives below the ▾ fold. Data layer untouched.
// ============================================================================

struct UsageView: View {
    @ObservedObject var state: UsageState
    @AppStorage(PanelMetrics.expandedKey) private var detailsExpanded = false
    @State private var compactHeight: CGFloat = PanelMetrics.height(expanded: false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Edge fades only show where there is more to scroll, so content at
    // rest is never dimmed.
    @State private var moreAbove = false
    @State private var moreBelow = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    // Snapshot renders show the details by default so fixtures cover the cards;
    // CODEX_USAGE_HUD_SNAPSHOT_COLLAPSED=1 renders the folded state.
    private var expanded: Bool { SnapshotMode.enabled ? !SnapshotMode.collapsed : detailsExpanded }

    /// Before the first setup has produced any reading, the setup card is the
    /// whole story: a WAIT verdict over "sign in" rows would only compete with it.
    private var setupOnly: Bool {
        let phase = state.setupCard.phase
        return (phase == .prompt || phase == .running)
            && !state.snapshots.contains(where: { detailProviders.contains($0.provider.lowercased()) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar(state: state)
                // Pinned to the content width: in the live panel the header
                // grew past it with a long status ("Codex · updated 23m ago")
                // and the pill was clipped at the edge.
                .frame(width: PanelMetrics.width - 2 * HUD.lg)
                .padding(.horizontal, HUD.lg)
                .padding(.top, HUD.md + 2)
                .padding(.bottom, HUD.sm)
                .background(ChromeHeightReader())

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: HUD.md) {
                    if state.setupCard.isVisible {
                        SetupCardView(state: state)
                            .padding(.horizontal, HUD.lg)
                    }
                    if detailProviders.isEmpty {
                        if !state.setupCard.isVisible {
                            EmptyUsageView()
                                .padding(.horizontal, HUD.lg)
                        }
                    } else if !setupOnly {
                        // Reset pings live on each lane's bell; the full card
                        // (history, explanation) moved to Settings.
                        StatusPanel(state: state, mode: heroMode, tagline: hero.tagline, alternative: heroAlternative,
                                    primary: primaryBudgetSnapshot, verdictCoversPrimaryAge: heroMode.raw == "check")
                            .padding(.horizontal, HUD.lg)

                        if state.snapshots.contains(where: { detailProviders.contains($0.provider.lowercased()) }) {
                            FoldToggle(expanded: expanded) { toggleDetails() }
                                .padding(.horizontal, HUD.lg)
                                .padding(.top, HUD.xs)

                            if expanded {
                                VStack(spacing: HUD.sm) {
                                    ForEach(detailProviders, id: \.self) { provider in
                                        if let snapshot = UsageInsights.snapshot(for: provider, in: state.snapshots) {
                                            ProviderDetailCard(
                                                snapshot: snapshot,
                                                budget: state.budgets[provider],
                                                state: state
                                            )
                                            .id(provider)
                                        }
                                    }
                                }
                                .padding(.horizontal, HUD.lg)
                            }
                        }
                    }

                    if let error = state.loadError {
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HUD.slow)
                            .padding(.horizontal, HUD.lg)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, HUD.lg)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ContentHeightKey.self, value: geo.size.height)
                            .preference(key: ScrollOffsetKey.self, value: -geo.frame(in: .named(PanelScroll.space)).minY)
                    }
                )
            }
            .coordinateSpace(name: PanelScroll.space)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                }
            )
            .mask(EdgeFadeMask(top: moreAbove, bottom: moreBelow))
            .onPreferenceChange(ScrollOffsetKey.self) { offset in
                scrollOffset = offset
                updateEdgeFades()
            }
            .onPreferenceChange(ViewportHeightKey.self) { height in
                viewportHeight = height
                updateEdgeFades()
            }
            .onPreferenceChange(ContentHeightKey.self) { measured in
                contentHeight = measured
                updateEdgeFades()
                guard !SnapshotMode.enabled, measured > 0, !expanded else { return }
                let previous = PanelMetrics.measuredCompactContent
                PanelMetrics.measuredCompactContent = measured
                let next = PanelMetrics.height(expanded: false)
                if abs(next - compactHeight) > 1 { compactHeight = next }
                if previous == nil || abs((previous ?? 0) - measured) > 1 {
                    NotificationCenter.default.post(name: PanelMetrics.heightDidChange, object: nil)
                }
            }

            FooterBar(state: state)
                .padding(.horizontal, HUD.lg)
                .padding(.vertical, HUD.sm + 2)
                .overlay(Rectangle().fill(HUD.hair).frame(height: 0.5), alignment: .top)
                .background(ChromeHeightReader())
        }
        .frame(width: 420, height: SnapshotMode.height ?? (expanded ? PanelMetrics.height(expanded: true) : compactHeight), alignment: .topLeading)
        .background(
            ZStack {
                if SnapshotMode.enabled { Color(hex: 0x0E0F15) }  // opaque base for offscreen capture
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow, appearance: .darkAqua)
                // Graphite tint over the glass: the desktop still shows through
                // faintly, but every wallpaper reads as the same dark panel.
                HUD.base.opacity(0.84)
                LinearGradient(colors: [Color.white.opacity(0.04), Color.clear], startPoint: .top, endPoint: .center)
                    .allowsHitTesting(false)
                RadialGradient(
                    colors: [heroMode.color.opacity(0.10), Color.clear],
                    center: .init(x: 0.2, y: 0.02), startRadius: 4, endRadius: 260
                )
                .allowsHitTesting(false)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(ChromeHeightKey.self) { chrome in
            guard !SnapshotMode.enabled, chrome > 0, abs(chrome - PanelMetrics.chromeHeight) > 1 else { return }
            PanelMetrics.chromeHeight = chrome
            let next = PanelMetrics.height(expanded: false)
            if !expanded, abs(next - compactHeight) > 1 { compactHeight = next }
            NotificationCenter.default.post(name: PanelMetrics.heightDidChange, object: nil)
        }
    }

    private func toggleDetails() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { detailsExpanded.toggle() }
        NotificationCenter.default.post(name: PanelMetrics.heightDidChange, object: nil)
    }

    /// Flip the fades only when they change, so scrolling doesn't re-render
    /// the panel every frame.
    private func updateEdgeFades() {
        let above = scrollOffset > 1
        let below = viewportHeight > 0 && contentHeight - scrollOffset - viewportHeight > 1
        if above != moreAbove { moreAbove = above }
        if below != moreBelow { moreBelow = below }
    }

    private var detailProviders: [String] {
        presentationSorted(UsageInsights.visibleProviderOrder(snapshots: state.snapshots, budgets: state.budgets))
    }

    // Anchor the daily/horizon budget to Claude — it's the primary spend lane and
    // what "my daily budget" means to most people, so the strip stays stable instead
    // of jumping providers. The hero separately tracks the cross-provider tightest;
    // every provider's own TODAY room is in its detail card.
    private var primaryBudgetSnapshot: UsageSnapshot? {
        let visible = Set(detailProviders)
        let visibleSnapshots = state.snapshots.filter { visible.contains($0.provider.lowercased()) }
        let claude = visible.contains("claude") ? UsageInsights.snapshot(for: "claude", in: visibleSnapshots) : nil
        if let claude, claude.week != nil || claude.currentSession != nil { return claude }
        if let b = bindingConstraint(visibleSnapshots) {
            return UsageInsights.snapshot(for: b.provider, in: visibleSnapshots)
        }
        return claude ?? visibleSnapshots.first
    }

    // Verdict follows the primary lane (Claude when shown). Other lanes are
    // surfaced by the low-lane warning + offload nudge, so a tight secondary
    // lane no longer makes the whole HUD read "WATCH" when the work you're
    // doing is actually fine. HeroVerdict names the lane, needs its own
    // reading to be fresh for a GO, and never shows GO beside a lane that is
    // running hot.
    private var hero: HeroVerdict.Result {
        guard let snap = primaryBudgetSnapshot else {
            return HeroVerdict.resolve(mode: "unknown", laneName: nil, readingFresh: false, paceStatus: nil)
        }
        let raw: String
        if let m = state.budgets[snap.provider.lowercased()]?.mode { raw = m }
        else if let p = pressWindow(snap) { raw = BudgetEvaluator.fallbackModeFromHeadroom(p.headroom) }
        else { raw = "unknown" }
        let reading = HeroVerdict.reading(for: snap)
        return HeroVerdict.resolve(
            mode: raw,
            laneName: UsageInsights.label(for: snap.provider.lowercased()),
            readingFresh: reading.fresh,
            paceStatus: lanePace(snap).status,
            staleReason: reading.why
        )
    }

    private var heroMode: ModeStyle { ModeStyle(hero.mode) }

    /// "Codex has room · 22% used" under a WATCH/STOP verdict: the next move.
    private var heroAlternative: String? {
        let lanes: [HeroVerdict.Lane] = detailProviders.compactMap { provider in
            guard provider != "local",
                  !UsageInsights.isManualObservationLane(provider, snapshots: state.snapshots),
                  let snap = UsageInsights.snapshot(for: provider, in: state.snapshots) else { return nil }
            let pace = lanePace(snap)
            // Only point at a lane whose number is current: not old, no
            // refresh problem, and read within the last half hour.
            let fresh = UsageInsights.laneFreshness(for: snap)
            return HeroVerdict.Lane(
                name: UsageInsights.label(for: provider),
                used: pace.historical || pace.derived ? nil : pace.used,
                paceStatus: pace.status,
                fresh: !fresh.needsAttention && (fresh.age ?? .infinity) <= 30 * 60
                    && UsageInsights.isReadingFresh(snap, within: 30 * 60)
            )
        }
        let primary = primaryBudgetSnapshot.map { UsageInsights.label(for: $0.provider.lowercased()) }
        return HeroVerdict.alternative(mode: hero.mode, primary: primary, lanes: lanes)
    }
}

// MARK: - Header

func headerHasHealthWarning(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
    if snapshot.health?.isWarning == true { return true }

    // A durable auth failure needs a human no matter how fresh the tap-fed
    // windows are: an unauthorized or missing credential means the official
    // Fable/weekly reading cannot come back on its own, so the live-window
    // bypass below must not hide it. Every other non-ok status (offline,
    // rate_limited, unparsed, aborted, unsettled, failed) still gets that
    // bypass, since those can clear themselves once the endpoint or the
    // scrape recovers.
    if let officialStatus = snapshot.officialUsageStatus?.status?.lowercased(),
       ["unauthorized", "no_credential", "token_expired"].contains(officialStatus) {
        return true
    }

    // A live 5h/week window (event within the last 15 minutes) already
    // proves the pipeline is working, but only reaches this check when the
    // writer-computed `health` above was not itself a warning, and when the
    // official status check above did not already return true. Precedence
    // runs health first, the durable-auth check second, the live-window
    // bypass third, never in any other order: a warning the writer actually
    // reported always flags the header, and a revoked token always flags it
    // too. The keepalive writer now reports health fresh whenever the tap
    // event is under 15 minutes old, so in practice health and the bypass
    // rarely disagree; this bypass matters for the remaining case, where
    // health is absent or stale rather than an active warning. Don't let a
    // failed official refetch that is not a durable auth failure (endpoint
    // offline, still unparsed) flag the header while the tap is still
    // current. The detail card's health line still shows it.
    if UsageInsights.hasLiveWindow(for: snapshot, now: now) { return false }

    if snapshot.officialUsageStatus?.isWarning == true { return true }
    guard snapshot.providerHealth?.isWarning == true else { return false }

    // Match the detail-card reconciliation rule: a newer healthy official
    // result clears an older legacy warning instead of keeping the header red.
    if let official = snapshot.officialUsageStatus, !official.isWarning,
       let officialAt = UsageInsights.parseDate(official.updatedAt),
       let providerAt = UsageInsights.parseDate(snapshot.providerHealth?.updatedAt),
       officialAt > providerAt {
        return false
    }
    return true
}

private struct HeaderBar: View {
    @ObservedObject var state: UsageState

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                AppMark().frame(width: 22, height: 22)
                HStack(spacing: 5) {
                    Text("Usage").font(.system(size: 15, weight: .bold, design: .rounded)).tracking(0.2)
                    Text("HUD").font(.system(size: 15, weight: .semibold, design: .rounded))
                        .tracking(1.0).foregroundStyle(HUD.ink3)
                }
            }
            Spacer()
            let status = headerStatus
            HStack(spacing: 5) {
                BreathingDot(color: statusColor(status))
                Text(status.text)
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.2)
                    .foregroundStyle(HUD.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(HUD.hair, lineWidth: 0.5))
            // A new identity per text: the live panel kept the old width when
            // "Claude · old" became "Claude · sign in again" and clipped it.
            .id(status.text)
            .layoutPriority(1)
            .help(status.help + "\n" + refreshedLine)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Readings: \(LaneSpeech.words(status.text))")
        }
    }

    /// The worst visible lane, in the words its row uses (see `LaneFreshness`).
    /// Fable rides inside the Claude row, so it only speaks when Claude doesn't.
    private var headerStatus: HeaderStatus {
        let visible = UsageInsights.visibleProviderOrder(snapshots: state.snapshots, budgets: state.budgets)
        var lanes: [HeaderStatus.Lane] = []
        for provider in visible {
            // A manual/observation lane shows its own age and never drives
            // the chip.
            guard !UsageInsights.isManualObservationLane(provider, snapshots: state.snapshots),
                  let snap = UsageInsights.snapshot(for: provider, in: state.snapshots) else { continue }
            let fresh = UsageInsights.laneFreshness(for: snap)
            lanes.append(.init(name: UsageInsights.label(for: provider), freshness: fresh))
            if provider == "claude", !fresh.needsAttention {
                let expired = snap.rateLimitExpired?.contains("weekFable") == true
                if FableDisplay.shouldShow(week: snap.weekFable, expired: expired) {
                    let fable = FableDisplay.make(week: snap.weekFable, expired: expired)
                    if let f = fable.freshness { lanes.append(.init(name: "Fable", freshness: f)) }
                }
            }
        }
        return HeaderStatus.make(lanes: lanes)
    }

    private func statusColor(_ status: HeaderStatus) -> Color {
        if state.loadError != nil { return HUD.slow }
        switch status.tone {
        case .live: return HUD.go
        case .recent: return HUD.ink3
        case .attention: return HUD.watch
        case .idle: return HUD.wait
        }
    }

    private var refreshedLine: String {
        state.lastLoadedAt.map { "Panel checked \(relative($0))." } ?? "Panel not loaded yet."
    }
}

// MARK: - Hero verdict

/// Hero verdict + lanes. The plain-English verdict ("Claude: clear to build")
/// is the focal point — big, bright, first thing read. It is Claude's
/// verdict specifically (the primary spend lane), not a blanket "everything
/// is fine": a GO only shows when Claude's own reading is under 15 minutes
/// old, falling back to a neutral CHECK otherwise. The tightest binding
/// window sits under it; then each lane as a bar row in its own identity color.
private struct StatusPanel: View {
    @ObservedObject var state: UsageState
    let mode: ModeStyle
    let tagline: String
    let alternative: String?
    let primary: UsageSnapshot?
    /// The verdict line already names the primary lane's old reading, so
    /// the caveat below it doesn't repeat it.
    var verdictCoversPrimaryAge = false

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.md) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 10) {
                    VerdictPill(mode: mode)
                        .help(whyHelp)
                    Text(tagline)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(HUD.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(mode.spokenWord). \(tagline)")
                if let alternative {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(HUD.go)
                            .accessibilityHidden(true)
                        Text(alternative)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(HUD.ink2)
                        Spacer(minLength: 0)
                    }
                    .help("Another lane you pay for has room right now. Switch to it while this one recovers.")
                }
                if let caveat = UsageInsights.trustCaveat(snapshots: state.snapshots, budgets: state.budgets,
                                                          excluding: caveatExclusions) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(HUD.watch).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                            .accessibilityHidden(true)
                        Text(noWidow(caveat))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HUD.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .help("Each lane says where its number came from. A reading marked old stopped refreshing, so it describes the past, not right now.")
                }
            }
            FoundProviderBanner()
            LaneBars(state: state, pings: state.resetPings,
                     primaryProvider: primary?.provider.lowercased(), accent: mode.color)
                .padding(.top, 2)
                .overlay(Rectangle().fill(HUD.hair).frame(height: 0.5), alignment: .top)
            SpendValueLine(state: state)
            PingStrip(controller: state.resetPings)
        }
    }

    private var caveatExclusions: Set<String> {
        guard verdictCoversPrimaryAge, let p = primary?.provider.lowercased() else { return [] }
        return [p]
    }

    // The old "Why:" line, demoted to hover: which window drives the verdict
    // plus what this mode allows (ModeStyle.reassure).
    private var whyHelp: String {
        var parts: [String] = [mode.reassure]
        if let snap = primary, let p = pressWindow(snap) {
            let reset = shortReset(p.reset, nil).map { ", resets \($0)" } ?? ""
            parts.append("Based on the \(UsageInsights.label(for: snap.provider)) \(p.label) limit: \(formatPercent(100 - p.headroom)) used\(reset).")
        }
        return parts.joined(separator: "\n")
    }
}

private struct VerdictPill: View {
    let mode: ModeStyle
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: mode.icon).font(.system(size: 10.5, weight: .bold))
            Text(mode.word).font(.system(size: 12.5, weight: .heavy, design: .rounded)).tracking(0.6)
        }
        .foregroundStyle(mode.onColor)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(mode.color))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Bars (one grammar: hero, lanes, windows)

/// Lane bar: a quiet recessed track with a flat fill, plus the pace tick.
/// Bar length is the primary (non-color) status cue; the tick marks how much
/// of the window's time has passed, so fill past it means running hot.
private struct PremiumBar: View {
    var fraction: Double          // 0…1
    var color: Color
    var height: CGFloat = 7
    var marker: Double? = nil     // 0…1 comparison tick (time elapsed in the window)

    var body: some View {
        GeometryReader { geo in
            let f = max(0, min(1, fraction.isFinite ? fraction : 0))
            let w = max(f > 0 ? height : 0, geo.size.width * f)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))

                if f > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [color, color.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                        .frame(width: w)
                }

                // Pace tick: a thin rule that stands a little proud of the
                // track so it reads as a marker, not a render seam.
                if let marker, marker.isFinite {
                    let m = max(0, min(1, marker))
                    let x = max(1, min(geo.size.width - 1, geo.size.width * m))
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(HUD.ink.opacity(0.85))
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: x - 0.75)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: height)
    }
}

/// Generic across every `ProviderCatalog` entry: one line per lane
/// `ToolDetection` finds installed/active that the current preferences do
/// not show yet ("Found Grok — add it?"). Add turns the lane on the same
/// way its Settings toggle would; Not now dismisses the prompt for that
/// lane without enabling it, and stays dismissed across launches.
private struct FoundProviderBanner: View {
    var body: some View {
        let providers = ProviderPreferences.foundButNotShown()
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(providers) { provider in
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HUD.watch)
                        Text("Found \(provider.name) \u{2014} add it?")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(HUD.ink2)
                        Spacer(minLength: 0)
                        Button("Add") {
                            ProviderPreferences.addDetectedProvider(provider.id)
                        }
                        .controlSize(.small)
                        Button("Not now") {
                            ProviderPreferences.dismissFoundPrompt(provider.id)
                        }
                        .controlSize(.small)
                        .buttonStyle(.plain)
                        .foregroundStyle(HUD.ink3)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(HUD.cardFill)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HUD.cardStroke, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Shared column grid for every lane row, so names, bars, percentages and
/// bells line up down the panel and sub-lines start under the bar.
private enum LaneGrid {
    static let name: CGFloat = 104
    static let gap: CGFloat = 10
    static let value: CGFloat = 42
    static let bell: CGFloat = 16
    /// Where a lane name's text starts (after its 13pt dot and 7pt gap).
    static let nameText: CGFloat = 20
    static var subLead: CGFloat { name + gap }
    static var subTrail: CGFloat { bell + gap }
}

/// Every lane as an identical SPEND-vs-CLOCK pace block (Snowflake's
/// spend/interval pattern): the bar is % of the window spent and the tick is
/// % of the window's time elapsed. The gap between the two IS the pace
/// verdict, so a fully-burned lane reads "Spent · back Sun Oct 4, 9 PM"
/// (target hit under the 100%-utilization policy) instead of a red alarm.
private struct LaneBars: View {
    @ObservedObject var state: UsageState
    @ObservedObject var pings: ResetPingController
    var primaryProvider: String?
    var accent: Color = HUD.go

    var body: some View {
        let lanes = presentationSorted(
            UsageInsights.visibleProviderOrder(snapshots: state.snapshots, budgets: state.budgets)
        )
        if !lanes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.element) { index, p in
                    VStack(alignment: .leading, spacing: 10) {
                        if let snapshot = UsageInsights.snapshot(for: p, in: state.snapshots) {
                            if p == "local" {
                                LocalUsageBlock(snapshot: snapshot)
                            } else {
                                PaceBlock(provider: p, snapshot: snapshot,
                                          isPrimary: p == primaryProvider, accent: accent,
                                          pings: ResetPingController.providers.contains(p) ? pings : nil,
                                          note: CreditsDisplay.laneNote(snapshot.credits))
                            }
                            if p == "claude" {
                                let fableExpired = snapshot.rateLimitExpired?.contains("weekFable") == true
                                if FableDisplay.shouldShow(week: snapshot.weekFable, expired: fableExpired) {
                                    FableRow(week: snapshot.weekFable, expired: fableExpired)
                                }
                            }
                        } else {
                            EmptyLaneRow(provider: p)
                        }
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(HUD.hairSoft).frame(height: 0.5) }
                    }
                }
            }
        }
    }
}

/// The name a lane row prints. The rows share a fixed name column, and
/// "Local Models" only fit by shrinking below the other names.
private func laneTitle(_ provider: String) -> String {
    provider == "local" ? "Local" : UsageInsights.label(for: provider)
}

/// The left column of a lane row: identity dot (ringed on the lane that
/// drives the verdict), the lane name, and an optional trailing accessory.
private struct LaneName<Accessory: View>: View {
    let title: String
    let dot: Color
    var ring: Color? = nil
    var small = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        // Explicit gaps: a uniform HStack spacing also padded the spacer,
        // which left "Claude" too little room beside its window tag.
        HStack(spacing: 0) {
            ZStack {
                if let ring {
                    Circle().strokeBorder(ring.opacity(0.85), lineWidth: 1.25)
                        .frame(width: 13, height: 13)
                }
                Circle().fill(dot).frame(width: small ? 5 : 7, height: small ? 5 : 7)
            }
            .frame(width: 13, height: 13)
            .padding(.trailing, LaneGrid.nameText - 13)
            Text(title)
                .font(.system(size: small ? 11.5 : 13, weight: small ? .medium : .semibold))
                .foregroundStyle(small ? HUD.ink2 : HUD.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            accessory()
        }
        .frame(width: LaneGrid.name, alignment: .leading)
    }
}

extension LaneName where Accessory == EmptyView {
    init(title: String, dot: Color, ring: Color? = nil, small: Bool = false) {
        self.init(title: title, dot: dot, ring: ring, small: small) { EmptyView() }
    }
}

/// Second line of a lane row: where the number came from sits under the
/// lane's name, and the lane's key fact (reset, stale age) runs under the bar.
private struct LaneSubline: View {
    let text: String?
    var textColor: Color = HUD.ink2
    /// The lane's freshness note ("updated 25m ago", "not refreshing"),
    /// from the same `LaneFreshness` the header pill reads.
    var freshness: LaneFreshness? = nil
    var trust: UsageInsights.LaneTrust?
    var indent: CGFloat = 0

    var body: some View {
        let note = freshness?.note
        let noteColor = freshness?.needsAttention == true ? HUD.watch : HUD.ink3
        HStack(alignment: .firstTextBaseline, spacing: LaneGrid.gap) {
            Group {
                if let trust { TrustTag(trust: trust) } else { Color.clear.frame(height: 1) }
            }
            .padding(.leading, LaneGrid.nameText + indent)
            .frame(width: LaneGrid.name, alignment: .leading)
            (Text(text ?? "").foregroundStyle(textColor)
             + Text(text != nil && note != nil ? " · " : "").foregroundStyle(HUD.ink3)
             + Text(note ?? "").foregroundStyle(noteColor))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .optionalHelp(freshness?.issueDetail)
    }
}

private extension View {
    /// A tooltip only when there is something to say, so an empty one never
    /// hides the row's own tooltip.
    @ViewBuilder func optionalHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty { self.help(text) } else { self }
    }
}

private struct LocalUsageBlock: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let today = snapshot.session?.todayTotal ?? 0
        let week = snapshot.session?.weekTotal ?? 0
        // Same two-line grammar as the bar lanes: tokens where the bar would
        // be, provenance under the name.
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: LaneGrid.gap) {
                LaneName(title: "Local", dot: HUD.local)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                (Text(compactTokenCount(today)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(HUD.ink)
                 + Text(" tokens today").font(.system(size: 10.5, weight: .medium)).foregroundStyle(HUD.ink2))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            LaneSubline(text: "\(compactTokenCount(week)) this week", textColor: HUD.ink3,
                        trust: UsageInsights.laneTrust(for: snapshot))
        }
        .help("Tokens your local models (Ollama) read and wrote, counted from Ollama's logs on this Mac. Local models have no usage limit.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Local models, \(compactTokenCount(today)) tokens today, \(compactTokenCount(week)) this week")
    }
}

/// Pure display logic for the Fable row, split out from the view so a missing
/// reading can never be tested (or accidentally coded) into a false "0%".
/// The row's only data source is the official weekly "Current week (Fable)"
/// reading — there is no other fallback source.
enum FableDisplay {
    struct Result: Equatable {
        let usedPct: Double?     // nil = no reading; the view must show "--", never 0.
        let percentText: String
        let subline: String
        let helpText: String
        let elapsedPct: Double?  // % of the weekly window's wall-clock elapsed; nil = no reset time
        let trust: UsageInsights.LaneTrust
        /// The reset part of `subline` alone, so the row can color the age
        /// note the way every other lane does.
        var resetText: String? = nil
        /// How current the reading is, in the panel's one vocabulary. Nil
        /// when there is no reading or it carries no stamp of its own (it
        /// then rides on the Claude row's freshness).
        var freshness: LaneFreshness? = nil
    }

    /// The keepalive writer refetches the official reading whenever it is
    /// older than 10 minutes, so past an hour the refetch itself is failing,
    /// not the panel simply waiting between ticks.
    static let oldAfter: TimeInterval = 60 * 60

    static func shouldShow(week: UsageSnapshot.WindowMetric?, expired: Bool) -> Bool {
        week?.usedPct != nil || expired
    }

    static func make(week: UsageSnapshot.WindowMetric?, expired: Bool, now: Date = Date()) -> Result {
        guard let pct = week?.usedPct else {
            return Result(
                usedPct: nil,
                percentText: "--",
                subline: "no reading yet · refreshes about every 5 min",
                helpText: "Fable's own weekly limit on your Claude plan, from Claude's official usage page. There's no reading since the last reset; the panel checks about every 10 minutes. If it stays empty, open Claude Code once so it can sign in again.",
                elapsedPct: nil,
                trust: UsageInsights.LaneTrust(
                    level: "unknown", label: "Unknown",
                    note: "No Fable weekly reading has come in since the last reset.",
                    rank: 3, isLive: false, ageDetail: nil)
            )
        }
        // Same formatter as the Claude row above it, not the writer's raw
        // label, so the two rows read as one lane.
        let reset = laneResetText(week?.resetLabel, week?.resetAt, now: now).flatMap { $0.isEmpty ? nil : "resets \($0)" }
        let freshness = UsageInsights.parseDate(week?.capturedAt)
            .map { LaneFreshness.make(readAt: $0, oldAfter: oldAfter, now: now) }
        let stale = freshness?.isOld == true
        // Same pace tick as the big lanes: % of the weekly window's wall-clock
        // elapsed. Fill behind the tick = room left; past it = running hot.
        var elapsed: Double?
        if let window = week,
           let resetDate = UsageInsights.resetDate(for: window, now: now),
           resetDate > now {
            elapsed = max(0, min(100, (1 - resetDate.timeIntervalSince(now) / (7 * 24 * 3600)) * 100))
        }
        var help = "Fable's own weekly limit on your Claude plan, from Claude's official usage page."
        if let e = elapsed {
            help += " The tick marks how much of the week has passed (\(formatPercent(e))). Behind the tick means room to spare; past it means you're using it faster than the week lasts."
        }
        if stale { help += " This reading should refresh about every 5 minutes. If it stays old, open Settings and click Run diagnostics." }
        // The row's number is the official reading, so it earns the Official
        // tag, but only while the refetch is still landing. Past the hour
        // that marks a broken refetch, the tag says "old" with everything else.
        let trust = UsageInsights.LaneTrust(
            level: "official", label: "Official",
            note: "Fable's own weekly limit, from Claude's official usage page.",
            rank: 0, isLive: !stale,
            ageDetail: freshness?.ageShort)
        let subline = [reset, freshness?.note].compactMap { $0 }.joined(separator: " · ")
        return Result(usedPct: pct, percentText: formatPercent(pct), subline: subline, helpText: help,
                      elapsedPct: stale ? nil : elapsed, trust: trust, resetText: reset, freshness: freshness)
    }
}

/// Fable rides on the Claude subscription, so it lives as a mini lane row
/// under Claude — same grid, smaller type, its own red fill. Bar = the
/// official "Current week (Fable)" limit used %. Hidden entirely (see
/// FableDisplay.shouldShow) until Fable has ever reported a weekly reading,
/// so this never claims a reading that doesn't exist.
private struct FableRow: View {
    let week: UsageSnapshot.WindowMetric?
    let expired: Bool
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var display: FableDisplay.Result { FableDisplay.make(week: week, expired: expired) }

    var body: some View {
        let target = display.usedPct ?? 0
        let still = SnapshotMode.enabled || reduceMotion
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: LaneGrid.gap) {
                // Neutral dot: at 0% a red identity dot read as a STOP signal,
                // so the brand red lives only on the bar fill.
                LaneName(title: "Fable", dot: HUD.ink3, small: true)
                    .padding(.leading, 12)
                    .frame(width: LaneGrid.name, alignment: .leading)

                PremiumBar(fraction: shown / 100, color: HUD.fable, height: 5,
                           marker: display.elapsedPct.map { $0 / 100 })

                Text(display.percentText)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(display.usedPct == nil ? HUD.ink3 : HUD.ink2)
                    .monospacedDigit()
                    .frame(width: LaneGrid.value, alignment: .trailing)

                Color.clear.frame(width: LaneGrid.bell, height: 1)
            }
            if !display.subline.isEmpty {
                LaneSubline(text: display.usedPct == nil ? display.subline : display.resetText,
                            textColor: HUD.ink3, freshness: display.freshness, trust: display.trust, indent: 12)
            }
        }
        .help(display.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LaneSpeech.fable(display, week: week))
        .onAppear { if still { shown = target } else { withAnimation(.easeOut(duration: 0.9).delay(0.25)) { shown = target } } }
        .onChange(of: target) { _, _ in if still { shown = target } else { withAnimation(.easeOut(duration: 0.5)) { shown = target } } }
    }
}

private struct PaceBlock: View {
    let provider: String
    let snapshot: UsageSnapshot?
    var isPrimary = false
    var accent: Color = HUD.go
    var pings: ResetPingController?
    var note: String?
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Per-lane window pin: "auto" (pressing window) / "5h" / "wk".
    @AppStorage private var pinned: String

    init(provider: String, snapshot: UsageSnapshot?, isPrimary: Bool = false, accent: Color = HUD.go,
         pings: ResetPingController? = nil, note: String? = nil) {
        self.provider = provider
        self.snapshot = snapshot
        self.isPrimary = isPrimary
        self.accent = accent
        self.pings = pings
        self.note = note
        _pinned = AppStorage(wrappedValue: "auto", "hud.laneWindow.\(provider)")
    }

    var body: some View {
        let pace = lanePace(snapshot, preferPressing: isPrimary, forced: pinned == "auto" ? nil : pinned)
        let freshness = UsageInsights.laneFreshness(for: snapshot)
        let trust = UsageInsights.displayTrust(for: snapshot, historical: pace.historical, derived: pace.derived)
        let target = pace.used ?? 0
        let still = SnapshotMode.enabled || reduceMotion
        // Daily room comes from the weekly limit, so it only sits beside the
        // weekly bar; next to a 5-hour reset it read as a 5-hour number.
        let todayNote = (isPrimary && !freshness.isOld && pace.windowTag != "5h" ? snapshot.flatMap { todayRoom($0) } : nil)
            .flatMap { $0.rowNote }
        let lines = LaneLines.make(pace, todayNote: todayNote, note: note, freshness: freshness)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: LaneGrid.gap) {
                LaneName(title: laneTitle(provider), dot: pace.barColor,
                         ring: isPrimary ? accent : nil) {
                    windowTag(pace)
                }

                PremiumBar(fraction: shown / 100, color: pace.historical ? HUD.ink3 : pace.barColor,
                           marker: freshness.isOld ? nil : pace.elapsed.map { $0 / 100 })

                Text(pace.used.map { formatPercent($0) } ?? "--")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(pace.used == nil || freshness.isOld || pace.historical ? HUD.ink3 : pace.valueColor)
                    .monospacedDigit()
                    .frame(width: LaneGrid.value, alignment: .trailing)

                Group {
                    if let pings {
                        PingBell(controller: pings, provider: provider)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: LaneGrid.bell)
            }
            LaneSubline(text: lines.primary, textColor: lines.primaryIsGap ? HUD.wait : HUD.ink2,
                        freshness: freshness, trust: trust)
            if let status = lines.status {
                Text(status)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(pace.statusColor)
                    .lineLimit(1)
                    .padding(.leading, LaneGrid.subLead)
            }
        }
        .help(rowHelp(pace))
        // One VoiceOver stop per lane, read the way a person would say it.
        // The bell and the window switch stay reachable as actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LaneSpeech.lane(name: UsageInsights.label(for: provider), pace: pace,
                                            resetSpoken: spokenReset(pace), freshness: freshness))
        .accessibilityAction(named: "Show \(nextPinName) limit") { cyclePin() }
        .modifier(BellAction(pings: pings, provider: provider))
        .onAppear { if still { shown = target } else { withAnimation(.easeOut(duration: 0.9).delay(0.2)) { shown = target } } }
        .onChange(of: target) { _, _ in if still { shown = target } else { withAnimation(.easeOut(duration: 0.5)) { shown = target } } }
    }

    /// The shown window's reset, said in full ("Tuesday, October 6 at 6:20 PM").
    private func spokenReset(_ pace: LanePace) -> String? {
        guard let snapshot else { return nil }
        let window = pace.windowTag == "5h" ? snapshot.currentSession : snapshot.week
        guard let window else { return nil }
        return laneResetSpoken(window.resetLabel, window.resetAt)
    }

    private var nextPinName: String {
        switch pinned {
        case "auto": return "5-hour"
        case "5h": return "weekly"
        default: return "closest"
        }
    }

    private func windowTag(_ pace: LanePace) -> some View {
        Button(action: cyclePin) {
            Text(pace.windowTag)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(pinned == "auto" ? HUD.ink3 : HUD.ink2)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.white.opacity(pinned == "auto" ? 0 : 0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(pinned == "auto"
              ? "Showing whichever limit is closer to running out. Click to always show the 5-hour limit."
              : "Always showing the \(pinned == "5h" ? "5-hour" : "weekly") limit. Click to show the \(nextPinName) limit.")
    }

    private func cyclePin() {
        switch pinned {
        case "auto": pinned = "5h"
        case "5h": pinned = "wk"
        default: pinned = "auto"
        }
    }

    private func rowHelp(_ pace: LanePace) -> String {
        let freshness = UsageInsights.laneFreshness(for: snapshot)
        if freshness.isOld {
            return "This is the last known reading, not a current estimate of available usage. " +
                (freshness.issueDetail ?? "Open Help for a health check and recovery steps.")
        }
        let window = LaneSpeech.windowName(pace.windowTag)
        var lines: [String] = []
        if let e = pace.elapsed {
            lines.append("The bar shows how much of the \(window) you've used. The tick marks how much of its time has passed (\(formatPercent(e))). Behind the tick means room to spare; past it means you're using it faster than it lasts.")
        } else {
            lines.append("The bar shows how much of the \(window) you've used. The reset time isn't known, so there's no tick.")
        }
        if pace.status == "ON PACE" { lines.append("On pace: your use is keeping up with the clock, not ahead of it.") }
        if isPrimary { lines.append("The ringed lane sets the verdict at the top. The daily figure is how much you can use each day and still last until the reset.") }
        return lines.joined(separator: "\n")
    }
}

/// The ping bell as a VoiceOver action on the lane, since the lane row is
/// one element and its bell button is no longer reachable on its own.
private struct BellAction: ViewModifier {
    var pings: ResetPingController?
    let provider: String

    func body(content: Content) -> some View {
        if let pings {
            let on = pings.enabled.contains(provider)
            let name = UsageInsights.label(for: provider)
            content.accessibilityAction(named: on ? "Stop reset ping for \(name)" : "Ping me when \(name) resets") {
                pings.setEnabled(provider, !on)
            }
        } else {
            content
        }
    }
}

/// What a lane row says under its bar. The reset time is always on the first
/// line when it is known (people plan around it), and a pace warning or
/// forecast gets its own colored second line instead of replacing it.
struct LaneLines: Equatable {
    var primary: String?
    /// The first line is itself the problem (no reading, window passed).
    var primaryIsGap = false
    var status: String?

    static func make(_ pace: LanePace, todayNote: String?, note: String? = nil, freshness: LaneFreshness? = nil) -> LaneLines {
        if let freshness, freshness.isOld {
            return LaneLines(primary: freshness.ageShort.map { "last read \($0) ago" },
                             primaryIsGap: true)
        }
        let resets = pace.reset.map { "resets \($0)" }
        let calm = [resets, todayNote, note].compactMap { $0 }.joined(separator: " · ")
        switch pace.status {
        case "✓ SPENT":
            return LaneLines(primary: ["Spent", pace.reset.map { "back \($0)" }, note].compactMap { $0 }.joined(separator: " · "))
        case "ALMOST SPENT":
            return LaneLines(primary: calm.nilIfEmpty, status: "Almost spent")
        case "5H FULL", "5H TIGHT":
            let head = pace.status == "5H FULL" ? "5-hour window full" : "5-hour window nearly full"
            return LaneLines(primary: calm.nilIfEmpty, status: [head, pace.sub].compactMap { $0 }.joined(separator: " · "))
        case "RUNNING HOT":
            return LaneLines(primary: calm.nilIfEmpty, status: ["Running hot", pace.sub].compactMap { $0 }.joined(separator: " · "))
        case "ROOM TO BURN":
            return LaneLines(primary: calm.nilIfEmpty, status: "Plenty of room")
        case "ON PACE", "RESETS SOON":
            return LaneLines(primary: calm.nilIfEmpty)
        case "PACE UNKNOWN":
            return LaneLines(primary: (calm.nilIfEmpty ?? "reset time unknown"))
        case "IDLE":
            return LaneLines(primary: [pace.sub, note].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
        default:
            // WAIT / RESET PASSED / NO DATA: the gap itself is the message.
            return LaneLines(primary: [pace.sub ?? "no reading yet", note].compactMap { $0 }.joined(separator: " · "),
                             primaryIsGap: true)
        }
    }
}

/// One bell per lane: on = a quiet Mac banner when this lane's exhausted
/// window is confirmed back. Replaces the old Reset Ping card on the panel;
/// the full card (history, snooze, explanation) lives in Settings.
private struct PingBell: View {
    @ObservedObject var controller: ResetPingController
    let provider: String
    @State private var hovering = false

    var body: some View {
        let on = controller.enabled.contains(provider)
        Button { controller.setEnabled(provider, !on) } label: {
            Image(systemName: on ? "bell.fill" : "bell")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? HUD.ink : (hovering ? HUD.ink2 : HUD.ink3.opacity(0.7)))
                .frame(width: LaneGrid.bell, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(on ? "Stop reset ping for \(UsageInsights.label(for: provider))" : "Ping me when \(UsageInsights.label(for: provider)) resets")
        .help(on ? "You'll get one quiet banner when \(UsageInsights.label(for: provider)) is back. Click to turn off."
                 : "Get one quiet banner when \(UsageInsights.label(for: provider)) is back after running out.")
    }
}

/// Only shows when the reset pings need a word: snoozed, or notifications
/// blocked. Otherwise the bells on each lane say everything.
private struct PingStrip: View {
    @ObservedObject var controller: ResetPingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let snoozed = controller.snoozeUntil.map { $0 > context.date } ?? false
            if snoozed || controller.notice != nil {
                HStack(spacing: 6) {
                    Image(systemName: snoozed ? "bell.slash" : "exclamationmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                    if let notice = controller.notice {
                        Text(notice).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else if let until = controller.snoozeUntil {
                        Text("Reset pings snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                    }
                    Spacer(minLength: 4)
                    if snoozed {
                        Button("Resume") { controller.resume() }
                            .buttonStyle(.plain)
                            .foregroundStyle(HUD.ink)
                    } else if controller.notice != nil {
                        Button(controller.needsSystemSettings ? "Open Settings" : "Allow") {
                            controller.fixPermission()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(HUD.ink)
                        .help(controller.needsSystemSettings
                              ? "Open System Settings › Notifications, then turn on Usage HUD"
                              : "Ask macOS to allow reset banners for Usage HUD")
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(controller.notice != nil ? HUD.watch : HUD.ink3)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Pace model (spend vs clock)

struct LanePace {
    let used: Double?       // % of the burn window spent; nil = unknown/expired
    let elapsed: Double?    // % of the window's wall-clock elapsed; nil = no reset time
    let windowTag: String   // "wk" / "day" / "5h" — which window the numbers describe
    let status: String
    let statusColor: Color
    let barColor: Color
    let valueColor: Color
    let sub: String?        // "back 7:00 PM" / "empty ~4:10 PM"
    // How old the reading is lives in `LaneFreshness`, not here, so the
    // row, its tag, the header and the verdict share one clock.
    var reset: String?      // shown window's reset, canonical short form
    /// True when `used` is a carried-over last-known reading from before the
    /// window expired, not a current one — the big percent + bar must render
    /// dimmed so it can't be mistaken for a live number.
    var historical: Bool = false
    /// True when `used` is the HUD's own inference rather than a number the
    /// provider reported. The idle-lane 0% is the case that matters: nothing
    /// ran, so the window is genuinely clear, but the provider never said
    /// "0%" and the trust chip must not claim it did.
    var derived: Bool = false
}

/// Pace verdict for a lane's burn window (week/quota; session fallback).
/// One rule for every lane: compare % spent against % of the window elapsed.
/// Under the 100%-utilization policy, ahead-of-clock is "running hot" (you'll
/// run dry early), behind-of-clock is "room to burn", and a finished lane is
/// calm success with its comeback time — never an alarm.
func lanePace(_ snapshot: UsageSnapshot?, preferPressing: Bool = false, forced: String? = nil, now: Date = Date()) -> LanePace {
    guard let snap = snapshot else {
        return LanePace(used: nil, elapsed: nil, windowTag: "", status: "NO DATA", statusColor: HUD.ink3,
                        barColor: HUD.ink3, valueColor: HUD.ink3, sub: nil)
    }
    let provider = snap.provider.lowercased()
    let identity = HUD.provider(provider)

    var window = snap.week
    // Gemini's burn window depends on the source: Antigravity quota is weekly
    // (label says "weekly"); the legacy Code Assist buckets reset daily.
    let geminiDaily = provider == "gemini" && snap.week?.label?.lowercased().contains("week") != true
    var tag = geminiDaily ? "day" : "wk"
    var duration: TimeInterval = geminiDaily ? 24 * 3600 : 7 * 24 * 3600
    if forced == "5h" {
        // User pinned the 5-hour window; honor it even when empty (an honest
        // WAIT/IDLE beats silently showing a window they didn't ask for).
        window = snap.currentSession
        tag = "5h"
        duration = 5 * 3600
    } else if forced == "wk" {
        // Keep the week/day window selected above.
    } else
    // The verdict lane shows the same window the verdict is computed from (the
    // more-pressing of 5h/weekly) so the pill and its lane can never disagree.
    if preferPressing, let s = snap.currentSession, let su = s.usedPct, su > (snap.week?.usedPct ?? -1) {
        window = s
        tag = "5h"
        duration = 5 * 3600
    } else if window?.usedPct == nil, snap.currentSession?.usedPct != nil {
        window = snap.currentSession
        tag = "5h"
        duration = 5 * 3600
    }
    guard let w = window, let used = w.usedPct else {
        if let w = window, w.isExpired {
            let event = w.eventAt ?? snap.eventAt ?? snap.updatedAt
            let last = w.displayUsedPct.map { "last \(formatPercent($0))" }
            let idleSince = event.map { "idle \(UsageInsights.ageText(for: $0))" }
            let detail = [last, idleSince, "limit is clear"].compactMap { $0 }.joined(separator: " · ")
            return LanePace(used: w.displayUsedPct, elapsed: nil, windowTag: tag, status: "IDLE", statusColor: HUD.ink2,
                            barColor: identity.opacity(0.45), valueColor: HUD.ink2, sub: detail, historical: true)
        }
        if let w = window, w.isUnknown {
            return LanePace(used: nil, elapsed: nil, windowTag: tag, status: "WAIT", statusColor: HUD.wait,
                            barColor: HUD.ink3, valueColor: HUD.ink3,
                            sub: w.reason ?? "limit not reported yet")
        }
        // No live window. If the lane's last event predates the expired window,
        // nothing ran since the rollover — the window is genuinely clear, which
        // is an answer, not a gap. Only a recent event with missing window data
        // means we're actually waiting on numbers.
        if let eventDate = UsageInsights.parseDate(snap.eventAt ?? snap.updatedAt),
           now.timeIntervalSince(eventDate) > 3600 {
            return LanePace(used: 0, elapsed: nil, windowTag: tag, status: "IDLE", statusColor: HUD.ink2,
                            barColor: identity.opacity(0.5), valueColor: HUD.ink2,
                            sub: "no runs since \(shortReset(nil, snap.eventAt ?? snap.updatedAt, now: now) ?? "a while") · limit is clear",
                            derived: true)
        }
        // No reading because the sign-in was refused: say how to fix it.
        if let status = snap.officialUsageStatus?.status?.lowercased(),
           ["unauthorized", "no_credential", "token_expired"].contains(status) {
            return LanePace(used: nil, elapsed: nil, windowTag: tag, status: "WAIT", statusColor: HUD.wait,
                            barColor: HUD.ink3, valueColor: HUD.ink3, sub: "open \(UsageInsights.label(for: snap.provider)) once")
        }
        return LanePace(used: nil, elapsed: nil, windowTag: tag, status: "WAIT", statusColor: HUD.wait,
                        barColor: HUD.ink3, valueColor: HUD.ink3, sub: "waiting for a new reading")
    }
    let backLabel = laneResetText(w.resetLabel, w.resetAt, now: now)

    let reset = UsageInsights.resetDate(for: w, now: now)
    if let reset, reset <= now {
        // The window already rolled over — the stored percentage predates the
        // reset. Showing it would be a lie; say so instead.
        return LanePace(used: nil, elapsed: nil, windowTag: tag, status: "RESET PASSED", statusColor: HUD.wait,
                        barColor: HUD.ink3, valueColor: HUD.ink3, sub: "reset passed · waiting for a new reading")
    }

    var elapsed: Double?
    if let reset {
        let remaining = reset.timeIntervalSince(now)
        elapsed = max(0, min(100, (1 - remaining / duration) * 100))
    }

    var pace: LanePace
    if used >= 99.5 {
        let back = backLabel.map { "back \($0)" }
        pace = LanePace(used: used, elapsed: elapsed, windowTag: tag, status: "✓ SPENT", statusColor: HUD.ink2,
                        barColor: identity.opacity(0.6), valueColor: HUD.ink2, sub: back)
    } else if used >= 90 {
        // Availability outranks pace: at <10% room the lane can't really take
        // work, so lead with the comeback time (gold, not alarm-red — running
        // a lane down is the policy's goal).
        pace = LanePace(used: used, elapsed: elapsed, windowTag: tag, status: "ALMOST SPENT", statusColor: HUD.watch,
                        barColor: identity, valueColor: HUD.watch,
                        sub: backLabel.map { "back \($0)" })
    } else if tag != "5h", let s = snap.currentSession, let su = s.usedPct, su >= 95,
              UsageInsights.resetDate(resetAt: s.resetAt, resetLabel: s.resetLabel, now: now).map({ $0 > now }) ?? true {
        // "Can I use this lane RIGHT NOW?" outranks weekly pace: the 5h session
        // is (nearly) tapped while the weekly bar still shows room.
        pace = LanePace(used: used, elapsed: elapsed, windowTag: tag,
                        status: su >= 99.5 ? "5H FULL" : "5H TIGHT", statusColor: HUD.watch,
                        barColor: identity, valueColor: HUD.ink,
                        sub: laneResetText(s.resetLabel, s.resetAt, now: now).map { "usable again \($0)" })
    } else if let reset, reset.timeIntervalSince(now) <= min(45 * 60, duration * 0.05) {
        // Window endgame: with (almost) no time left, pace advice is moot — the
        // imminent reset is the actionable fact.
        pace = LanePace(used: used, elapsed: elapsed, windowTag: tag, status: "RESETS SOON", statusColor: HUD.ink2,
                        barColor: identity, valueColor: HUD.ink,
                        sub: backLabel.map { "resets \($0)" })
    } else if let e = elapsed {
        let delta = used - e
        if delta > 15 {
            pace = LanePace(used: used, elapsed: e, windowTag: tag, status: "RUNNING HOT", statusColor: HUD.watch,
                            barColor: HUD.watch, valueColor: HUD.watch,
                            sub: emptyEstimate(used: used, elapsed: e, duration: duration, now: now))
        } else if delta < -15 {
            pace = LanePace(used: used, elapsed: e, windowTag: tag, status: "ROOM TO BURN", statusColor: HUD.go,
                            barColor: identity, valueColor: HUD.ink, sub: nil)
        } else {
            pace = LanePace(used: used, elapsed: e, windowTag: tag, status: "ON PACE", statusColor: HUD.ink2,
                            barColor: identity, valueColor: HUD.ink, sub: nil)
        }
    } else {
        pace = LanePace(used: used, elapsed: nil, windowTag: tag, status: "PACE UNKNOWN", statusColor: HUD.ink3,
                        barColor: identity, valueColor: HUD.ink, sub: nil)
    }
    pace.reset = backLabel
    return pace
}

/// One canonical reset format everywhere; the date is dropped when it's today
/// ("back 6:50 PM"), short for this week, full otherwise. Falls back to the
/// raw upstream label when unparseable.
/// Lays children out left to right and wraps to a new row when the next one
/// would not fit, each row vertically centered. Used for the window chips so
/// a third chip wraps instead of truncating the reset times.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 7
    var rowSpacing: CGFloat = 5

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var height: CGFloat = 0; var width: CGFloat = 0 }

    private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(Row())
                row = rows[rows.count - 1]
            }
            row.items.append((index, size))
            row.width = row.items.isEmpty ? 0 : (row.width == 0 ? size.width : row.width + spacing + size.width)
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let laid = rows(in: width, subviews: subviews)
        let height = laid.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, laid.count - 1)) * rowSpacing
        let widest = laid.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                let centered = y + (row.height - item.size.height) / 2
                subviews[item.index].place(at: CGPoint(x: x, y: centered), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }
}

private func shortReset(_ label: String?, _ resetAt: String?, now: Date = Date()) -> String? {
    guard let date = UsageInsights.resetDate(resetAt: resetAt, resetLabel: label, now: now) else { return label }
    let f = DateFormatter()
    if Calendar.current.isDate(date, inSameDayAs: now) {
        f.dateFormat = "h:mm a"
    } else if date.timeIntervalSince(now) < 6.5 * 24 * 3600 {
        f.dateFormat = "EEE h:mm a"
    } else {
        f.dateFormat = "MMM d h:mm a"
    }
    // "4 PM" not "4:00 PM": resets land on the hour almost always, and the
    // chips have no room for digits that carry nothing.
    if Calendar.current.component(.minute, from: date) == 0 {
        f.dateFormat = f.dateFormat.replacingOccurrences(of: "h:mm a", with: "h a")
    }
    // Near resets get a live countdown so "when is it back" needs zero math;
    // the countdown alone is the answer and fits the window chips.
    let remaining = date.timeIntervalSince(now)
    if remaining > 0, remaining <= 3 * 3600 {
        return "in \(countdownText(remaining))"
    }
    return f.string(from: date)
}

/// The lane rows' reset wording, written to be read at a glance and heard
/// aloud: "in 2h 10m" when close, "today 9:11 PM", "tomorrow 4 PM", else the
/// weekday and date ("Sun Oct 4, 9:11 PM"). Always carries the date once the
/// reset is past tomorrow, because "Sun 9 PM" alone made people do math.
/// Falls back to the raw upstream label when unparseable.
func laneResetText(_ label: String?, _ resetAt: String?, now: Date = Date()) -> String? {
    guard let date = UsageInsights.resetDate(resetAt: resetAt, resetLabel: label, now: now) else { return label }
    let remaining = date.timeIntervalSince(now)
    if remaining > 0, remaining <= 3 * 3600 { return "in \(countdownText(remaining))" }
    let calendar = Calendar.current
    let f = DateFormatter()
    f.dateFormat = calendar.component(.minute, from: date) == 0 ? "h a" : "h:mm a"
    let time = f.string(from: date)
    if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
        return "tomorrow \(time)"
    }
    f.dateFormat = "EEE MMM d"
    return "\(f.string(from: date)), \(time)"
}

/// The reset said in full for VoiceOver: "in 2 hours 10 minutes", "today at
/// 5 PM", "tomorrow at 12:30 PM", "Tuesday, October 6 at 6:20 PM".
func laneResetSpoken(_ label: String?, _ resetAt: String?, now: Date = Date()) -> String? {
    guard let date = UsageInsights.resetDate(resetAt: resetAt, resetLabel: label, now: now) else { return label }
    let remaining = date.timeIntervalSince(now)
    if remaining > 0, remaining <= 3 * 3600 {
        let minutes = Int((remaining / 60).rounded(.up))
        let h = minutes / 60, m = minutes % 60
        let hours = h == 0 ? nil : "\(h) hour\(h == 1 ? "" : "s")"
        let mins = m == 0 ? nil : "\(m) minute\(m == 1 ? "" : "s")"
        return "in " + [hours, mins].compactMap { $0 }.joined(separator: " ")
    }
    let calendar = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = calendar.component(.minute, from: date) == 0 ? "h a" : "h:mm a"
    let time = f.string(from: date)
    if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
        return "tomorrow at \(time)"
    }
    f.dateFormat = "EEEE, MMMM d"
    return "\(f.string(from: date)) at \(time)"
}

/// What VoiceOver says for a lane row: one sentence a person would say,
/// e.g. "Claude, 62 percent of weekly limit used, resets Tuesday, October 6
/// at 6:20 PM, running hot".
enum LaneSpeech {
    /// Expand compact durations for speech without changing the visible text.
    static func words(_ text: String) -> String {
        let pattern = #"\b([0-9]+)([smhd])\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let units = ["s": "second", "m": "minute", "h": "hour", "d": "day"]
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let unit = units[String(text[unitRange])] else { continue }
            let number = String(text[numberRange])
            result.replaceSubrange(range, with: "\(number) \(unit)\(Int(number) == 1 ? "" : "s")")
        }
        return result
    }

    static func windowName(_ tag: String) -> String {
        switch tag {
        case "5h": return "5-hour limit"
        case "day": return "daily limit"
        default: return "weekly limit"
        }
    }

    static func status(_ status: String) -> String? {
        switch status {
        case "RUNNING HOT": return "running hot"
        case "ROOM TO BURN": return "plenty of room"
        case "ON PACE": return "on pace"
        case "ALMOST SPENT": return "almost spent"
        case "✓ SPENT": return "spent"
        case "5H FULL": return "5-hour limit full"
        case "5H TIGHT": return "5-hour limit nearly full"
        case "RESETS SOON": return "resets soon"
        case "IDLE": return "idle"
        case "WAIT", "RESET PASSED", "NO DATA": return "waiting for a new reading"
        default: return nil
        }
    }

    static func lane(name: String, pace: LanePace, resetSpoken: String?, freshness: LaneFreshness?) -> String {
        var parts = [name]
        if let used = pace.used, used.isFinite {
            let pct = Int(used.rounded())
            parts.append(pace.historical || freshness?.isOld == true
                         ? "last reading \(pct) percent of \(windowName(pace.windowTag)) used"
                         : "\(pct) percent of \(windowName(pace.windowTag)) used")
        } else {
            parts.append("no reading")
        }
        if let resetSpoken, pace.used != nil { parts.append("resets \(resetSpoken)") }
        if freshness?.isOld != true, let status = status(pace.status), !(status == "resets soon" && resetSpoken != nil) { parts.append(status) }
        if let freshness { parts.append(contentsOf: spoken(freshness)) }
        return parts.joined(separator: ", ")
    }

    static func fable(_ display: FableDisplay.Result, week: UsageSnapshot.WindowMetric?) -> String {
        var parts = ["Fable"]
        if let used = display.usedPct {
            parts.append("\(Int(used.rounded())) percent of weekly limit used")
            if let reset = laneResetSpoken(week?.resetLabel, week?.resetAt) { parts.append("resets \(reset)") }
        } else {
            parts.append("no reading yet")
        }
        if let freshness = display.freshness { parts.append(contentsOf: spoken(freshness)) }
        return parts.joined(separator: ", ")
    }

    /// Only what needs saying: nothing when live.
    static func spoken(_ f: LaneFreshness) -> [String] {
        var out: [String] = []
        if let issue = f.issue { out.append(words(issue)) }
        switch f.state {
        case .live: break
        case .recent: if let age = f.ageSpoken { out.append("updated \(age) ago") }
        case .old: out.append(f.ageSpoken.map { "reading is \($0) old" } ?? "reading is old")
        }
        return out
    }
}

private func countdownText(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded(.up))
    if minutes < 60 { return "\(minutes)m" }
    let h = minutes / 60, m = minutes % 60
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

/// Linear projection: at the current burn rate, when does the window hit 100%?
private func emptyEstimate(used: Double, elapsed: Double, duration: TimeInterval, now: Date) -> String? {
    let elapsedSecs = duration * elapsed / 100
    guard used > 0, elapsedSecs > duration * 0.02 else { return nil }
    let rate = used / elapsedSecs
    let empty = now.addingTimeInterval((100 - used) / rate)
    let f = DateFormatter()
    f.dateFormat = empty.timeIntervalSince(now) < 22 * 3600 ? "h:mm a" : "EEE h a"
    return "runs out ~\(f.string(from: empty)) at this pace"
}

// MARK: - Daily budget + lanes (simplified overview)

/// The most-pressing window of a lane (the lower-headroom of 5-hour / weekly).
private func pressWindow(_ snap: UsageSnapshot) -> (headroom: Double, label: String, reset: String?)? {
    var worst: (used: Double, label: String, reset: String?)?
    if let s = snap.currentSession, let u = s.usedPct {
        worst = (u, "5-hour", s.resetLabel)
    }
    if let w = snap.week, let u = w.usedPct, worst == nil || u > worst!.used {
        worst = (u, snap.provider.lowercased() == "gemini" ? "quota" : "weekly", w.resetLabel)
    }
    guard let worst else { return nil }
    return (max(0, 100 - worst.used), worst.label, worst.reset)
}

private struct TodayRoom {
    let value: String
    let sub: String
    let color: Color
    var perDay: String? = nil

    /// The lane row's short form: "7% a day to last". Within a day of the
    /// reset the whole remainder is today's, and the row's percent says it.
    var rowNote: String? { perDay.map { "\($0) a day to last" } }
}

/// "How much can I spend today?" There is no hard daily cap on the weekly-limited
/// providers, so today's room = the weekly headroom you can spend now and still
/// pace evenly to reset. Within a day of reset, today simply holds the full
/// remaining headroom. Mirrors the original SpendBudgetGrid "Day room" logic.
private func todayRoom(_ snap: UsageSnapshot, now: Date = Date()) -> TodayRoom? {
    guard let room = UsageInsights.dailyRoom(for: snap, now: now) else { return nil }
    guard let spendable = room.spendablePct else {
        return TodayRoom(value: "--", sub: "reset unknown", color: HUD.ink3)
    }
    if room.usesFullHeadroom {
        let reset = shortReset(room.resetLabel, snap.week?.resetAt, now: now)
        return TodayRoom(
            value: formatPercent(spendable),
            sub: "left until the reset" + (reset.map { ", \($0)" } ?? ""),
            color: HUD.remainColor(room.headroomPct))
    }
    let days = room.daysToReset ?? 1
    return TodayRoom(
        value: formatPercent(spendable),
        sub: "a day until the reset, \(days) day\(days == 1 ? "" : "s") away",
        color: HUD.remainColor(room.headroomPct),
        perDay: formatPercent(spendable))
}

// MARK: - Fold toggle (details disclosure)

/// Panel geometry shared with the NSPanel controller: the window resizes
/// (anchored to its top edge) when the details fold opens or closes.
enum PanelMetrics {
    static let expandedKey = "hud.detailsExpanded"
    static let heightDidChange = Notification.Name("com.codexusagehud.panel-height-changed")
    static let width: CGFloat = 420
    /// Header + footer chrome that sits outside the measured scroll content.
    /// Starts at a safe estimate; the view replaces it with the measured value.
    static var chromeHeight: CGFloat = 80
    /// Measured natural height of the collapsed content, kept current by the
    /// view via a size preference so the folded panel hugs its content.
    static var measuredCompactContent: CGFloat?

    static func height(expanded: Bool) -> CGFloat {
        if expanded { return 620 }
        guard let content = measuredCompactContent else { return 545 }
        return min(620, max(320, content + chromeHeight))
    }

    static var preferredHeight: CGFloat {
        height(expanded: UserDefaults.standard.bool(forKey: expandedKey))
    }
}

/// Sums the header and footer heights so the folded panel hugs its content
/// even when the footer grows a second line.
private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private struct ChromeHeightReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ChromeHeightKey.self, value: geo.size.height)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum PanelScroll {
    static let space = "hud.panelScroll"
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Soft edges on the scroll area, only where more content sits past the
/// edge, so expanded details fade under the footer instead of being cut.
private struct EdgeFadeMask: View {
    let top: Bool
    let bottom: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, Color.black.opacity(bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 30)
        }
    }
}

private struct FoldToggle: View {
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Rectangle().fill(HUD.hair).frame(height: 0.5)
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Text(expanded ? "Hide details" : "Details")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(hovering ? HUD.ink2 : HUD.ink3)
                Rectangle().fill(HUD.hair).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "Hide each lane's details" : "Show each lane's limits, source and usage details")
        .accessibilityLabel(expanded ? "Hide details" : "Show details")
    }
}

// MARK: - Provider detail card

private struct ProviderDetailCard: View {
    let snapshot: UsageSnapshot
    let budget: BudgetState?
    @ObservedObject var state: UsageState

    var body: some View {
        let provider = snapshot.provider.lowercased()
        VStack(alignment: .leading, spacing: 10) {
            header
            windows
            todayRoomLine
            creditsLine
            localTokenLine
            localBreakdown
            sourceLine
            healthLine
            spendLine
            drivers
            if let credit = CreditPoolReader.load(for: provider) { CreditPoolCard(credit: credit) }
        }
        .padding(14)
        .background(Color.white.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var localTokenLine: some View {
        if snapshot.provider.lowercased() == "local", let session = snapshot.session {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                RowKey("Tokens")
                Text("\(compactTokenCount(session.todayTotal ?? 0)) today · \(compactTokenCount(session.weekTotal ?? 0)) this week · \(session.requestCount ?? 0) requests")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(HUD.ink2)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var localBreakdown: some View {
        if snapshot.provider.lowercased() == "local" {
            if !snapshot.contributors.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SectionCaption("Token mix")
                    ForEach(snapshot.contributors.prefix(2)) { item in
                        DriverRow(percent: item.percent, color: HUD.local, label: item.label, note: item.note)
                    }
                }
            }
            if !snapshot.skills.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SectionCaption("Models used")
                    ForEach(Array(snapshot.skills.prefix(4))) { item in
                        DriverRow(percent: item.percent, color: HUD.local, label: item.name, note: nil)
                    }
                }
            }
        }
    }

    /// Same words as the lane row's tag and the header pill: where the
    /// number came from, then how current it is ("official · live",
    /// "measured · old").
    private var header: some View {
        // The trust of the number the row shows (an idle lane's inferred 0%
        // is "estimated" even from an official source), so card and row agree.
        let pace = lanePace(snapshot)
        let trust = UsageInsights.displayTrust(for: snapshot, historical: pace.historical, derived: pace.derived)
        let fresh = UsageInsights.laneFreshness(for: snapshot)
        let dot: Color = fresh.needsAttention ? HUD.watch : (fresh.state == .live ? HUD.go : HUD.ink3)
        return HStack(spacing: 8) {
            Circle().fill(HUD.provider(snapshot.provider)).frame(width: 7, height: 7)
                .frame(width: 13, height: 13)
            Text(snapshot.displayName ?? snapshot.provider.capitalized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HUD.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 5, height: 5)
                // Exactly the row tag's words; an issue is spelled out on
                // the Status line below.
                Text("\(trust.word) · \(trust.isLive || trust.isGap ? fresh.label : "old")")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(fresh.needsAttention ? HUD.watch.opacity(0.9) : HUD.ink3)
                    .lineLimit(1)
            }
            .help(trust.help)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var windows: some View {
        let items = windowItems
        if !items.isEmpty {
            // Three chips overflow the card at 11pt; wrapping keeps every
            // reset time whole, and wrapped chips stay in the value column.
            HStack(alignment: .top, spacing: 7) {
                RowKey("Limits")
                    .padding(.top, 4)
                ChipFlow(spacing: 6, rowSpacing: 6) {
                    ForEach(items) { windowChip($0) }
                }
            }
        }
    }

    /// Compact chip per window — the bars live in the lane stack; the card only
    /// needs the numbers. Gold = nearly spent, ✓dim = spent, plain otherwise.
    private func windowChip(_ item: WindowItem) -> some View {
        let used = item.used
        let expired = item.state == "expired"
        let unknown = item.state == "unknown"
        let spent = used.map { $0 >= 99.5 } ?? false
        let tight = !spent && (used.map { $0 >= 90 } ?? false)
        let valueColor: Color = expired ? HUD.ink2 : (spent ? HUD.ink2 : (tight ? HUD.watch : HUD.ink))
        let reset = shortReset(item.reset, item.resetAt)
        let value = used.map(formatPercent) ?? "—"
        let prefix = spent && !expired ? "✓ " : ""
        let suffix = expired ? " · idle" : (reset.map { " · \($0)" } ?? "")
        let window = item.id == "session" ? "5-hour limit" : (item.id == "weekFable" ? "Fable weekly limit" : (item.title == "day" ? "daily limit" : "weekly limit"))
        let helpState = expired ? "nothing used since it reset; last reading \(value)" : (unknown ? (item.reason ?? "not reported yet") : "\(value) used")
        return (Text(prefix).foregroundStyle(HUD.ink2)
                + Text("\(item.title) ").foregroundStyle(HUD.ink3)
                + Text(value).foregroundStyle(valueColor).fontWeight(.bold)
                + Text(suffix).foregroundStyle(HUD.ink3))
            .font(.system(size: 11, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5))
            .help("\(window.prefix(1).uppercased() + window.dropFirst()): \(helpState)\(reset.map { ", resets \($0)" } ?? "").")
    }

    @ViewBuilder private var creditsLine: some View {
        if let text = CreditsDisplay.detail(snapshot.credits) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                RowKey("Credits")
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(HUD.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help("Prepaid credits. After the plan's own limit runs out, usage draws from this balance, which can cost money if automatic reload is on.")
        }
    }

    @ViewBuilder private var todayRoomLine: some View {
        // An old reading can't say how much is left to use today.
        if !UsageInsights.laneFreshness(for: snapshot).isOld, let t = todayRoom(snapshot) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                RowKey(t.perDay != nil ? "To last" : "Today")
                (Text(t.value).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(t.color)
                 + Text(" \(t.sub)").font(.system(size: 11, weight: .medium)).foregroundStyle(HUD.ink2))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(t.perDay != nil
                  ? "Use about this much of the weekly limit each day and it lasts until the reset."
                  : "The weekly limit resets within a day, so everything left is yours to use today.")
        }
    }

    private var sourceLine: some View {
        let fresh = UsageInsights.laneFreshness(for: snapshot)
        // Same freshness words as the header above it; an issue is said on
        // the status line below, so this line stays about time.
        let when: String = {
            switch fresh.state {
            case .live: return "live"
            case .recent: return fresh.label
            case .old: return fresh.age.map { "updated \(LaneFreshness.short($0)) ago" } ?? "no update time"
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            RowKey("Source")
            (Text(UsageInsights.plainSource(snapshot)).foregroundStyle(HUD.ink2)
             + Text(" · ").foregroundStyle(HUD.ink3)
             + Text(when).foregroundStyle(fresh.isOld && fresh.issue == nil ? HUD.watch : HUD.ink3))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(UsageInsights.sourceHelp(snapshot))
    }

    @ViewBuilder private var healthLine: some View {
        if let health = providerHealthMessage {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                RowKey("Status")
                Text(health.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(health.color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .help(health.detail)
        }
    }

    private var providerHealthMessage: (summary: String, detail: String, color: Color)? {
        // Writer-computed lane health (schema v2) outranks the legacy status
        // fields: it's the producer saying "don't trust my own numbers".
        if let lane = snapshot.health, lane.isWarning {
            let reason = lane.reason ?? "this lane's numbers may be old or wrong"
            let checked = lane.checkedAt.map { " Checked \(UsageInsights.ageText(for: $0))." } ?? ""
            let broken = lane.verdict?.lowercased() == "broken"
            let color: Color = broken ? HUD.stop : HUD.watch
            let head = broken ? "Not working" : "Not refreshing"
            return (cappedHealthSummary("\(head): \(reason)"), "\(head). \(reason)\(checked)", color)
        }
        // A stale providerHealth warning must not outrank a newer official-status
        // OK — the two fields are written by different producers on different
        // clocks and the fresher one is the truth.
        let legacyWarning: UsageSnapshot.ProviderHealth? = {
            guard let ph = snapshot.providerHealth, ph.isWarning else {
                return snapshot.officialUsageStatus?.isWarning == true ? snapshot.officialUsageStatus : nil
            }
            if let official = snapshot.officialUsageStatus, !official.isWarning,
               let officialAt = UsageInsights.parseDate(official.updatedAt),
               let warningAt = UsageInsights.parseDate(ph.updatedAt),
               officialAt > warningAt {
                return nil
            }
            return ph
        }()
        if let health = legacyWarning {
            let status = (health.status ?? health.reason ?? "warning").lowercased()
            let message: String
            if let exitCode = health.exitCode, exitCode != 0 {
                message = "The official usage check failed (code \(exitCode))"
            } else if let signal = health.signal, !signal.isEmpty {
                message = "The official usage check was stopped before it finished"
            } else if ["unauthorized", "no_credential", "token_expired"].contains(status) {
                message = health.message ?? "Sign-in expired. Open the app once to sign in again"
            } else {
                let plain = status.replacingOccurrences(of: "_", with: " ")
                message = health.message ?? (plain.prefix(1).uppercased() + plain.dropFirst())
            }
            let retry = health.retryAt.map { " Tries again \(UsageInsights.ageText(for: $0))." } ?? ""
            return (cappedHealthSummary(message), "\(message).\(retry)", HUD.watch)
        }
        return nil
    }

    private func cappedHealthSummary(_ value: String, limit: Int = 110) -> String {
        guard value.count > limit else { return value }
        return "\(value.prefix(max(0, limit - 1)))…"
    }

    private var windowItems: [WindowItem] {
        var out: [WindowItem] = []
        if let s = snapshot.currentSession,
           s.displayUsedPct != nil || s.isExpired || s.isUnknown {
            out.append(WindowItem(id: "session", title: "5h", used: s.displayUsedPct, reset: s.resetLabel,
                                  resetAt: s.resetAt, state: s.normalizedState, reason: s.reason))
        }
        if let w = snapshot.week,
           w.displayUsedPct != nil || w.isExpired || w.isUnknown {
            let daily = snapshot.provider.lowercased() == "gemini" && w.label?.lowercased().contains("week") != true
            out.append(WindowItem(id: "week", title: daily ? "day" : "wk", used: w.displayUsedPct, reset: w.resetLabel,
                                  resetAt: w.resetAt, state: w.normalizedState, reason: w.reason))
        }
        if let f = snapshot.weekFable,
           f.displayUsedPct != nil || f.isExpired || f.isUnknown {
            // Same reset as the wk chip — omit it so three chips fit the row.
            out.append(WindowItem(id: "weekFable", title: "Fable wk", used: f.displayUsedPct, reset: nil,
                                  resetAt: nil, state: f.normalizedState, reason: f.reason))
        }
        return out
    }

    /// The lane's spend from the in-app token readers, when it has any.
    private var nativeSpend: SpendSummary.Provider? {
        let provider = snapshot.provider.lowercased()
        guard PlanCatalog.providers.contains(provider) else { return nil }
        return state.spend?.provider(provider)
    }

    @ViewBuilder private var spendLine: some View {
        if let lane = nativeSpend {
            nativeSpendRows(lane)
        }
        if let extra = snapshot.extraUsage, !extra.isEmpty,
           extra.lowercased() != snapshot.provider.lowercased() {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                // Local models report which Macs' logs were counted, not a plan.
                RowKey(snapshot.provider.lowercased() == "local" ? "Logs" : (nativeSpend == nil ? "Plan" : "Details"))
                Text(extra)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HUD.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(extra)
        }
    }

    @ViewBuilder private func nativeSpendRows(_ lane: SpendSummary.Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = SpendDisplay.laneValue(lane) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    RowKey("API value")
                    (Text(value).foregroundStyle(HUD.ink2)
                     + Text("  \(SpendDisplay.notBilled)\(lane.apiValue?.estimated == true ? " · some models estimated" : "")").foregroundStyle(HUD.ink3))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .help(SpendDisplay.laneHelp(lane))
            }
            if let tokens = SpendDisplay.laneTokens(lane) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    RowKey("Tokens")
                    Text(tokens)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(HUD.ink2)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .help("Every token the model processed, cache reads and writes included.")
            }
            let plan = SpendDisplay.lanePlan(lane)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                RowKey("Plan")
                (Text(plan.text).foregroundStyle(plan.isSet ? HUD.ink2 : HUD.ink3)
                 + Text(plan.detail.map { "  \($0)" } ?? "").foregroundStyle(HUD.ink3))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if !plan.isSet {
                    SetPlanLink()
                }
            }
            .help(plan.isSet
                  ? "What you pay for \(UsageInsights.label(for: lane.provider)) each month\(lane.plan.source == "detected" ? ", read from this Mac" : ""). Change it in Settings › Plans."
                  : "Pick your plan in Settings › Plans to compare it with the API value.")
        }
    }

    @ViewBuilder private var drivers: some View {
        if let budget, !budget.driverAlerts.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                SectionCaption("What's pushing usage")
                ForEach(budget.driverAlerts) { a in
                    DriverRow(percent: a.percent, color: ModeStyle(a.severity).color, label: a.label, note: a.rule ?? a.note)
                }
            }
        }
    }

}

/// The token tracker prices usage at pay-per-use API rates ("$93 today").
/// On a flat subscription that is not money spent, and a "Spend" label led
/// people to read it as a bill, so dollars show as API value, apart from
/// the token counts they came from.
/// Codex keeps working past its weekly limit by drawing on prepaid credits,
/// so a lane that reads "empty ~10 AM" also says how many credits remain.
enum CreditsDisplay {
    static func laneNote(_ credits: UsageSnapshot.Credits?) -> String? {
        guard let credits else { return nil }
        if credits.unlimited == true { return "unlimited credits" }
        guard let balance = credits.balance, balance > 0 else { return nil }
        return "\(compactTokenCount(Int(balance.rounded()))) credits"
    }

    static func detail(_ credits: UsageSnapshot.Credits?) -> String? {
        guard let credits else { return nil }
        if credits.unlimited == true { return "unlimited · used after the plan limit" }
        guard let balance = credits.balance else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let amount = formatter.string(from: NSNumber(value: balance.rounded())) ?? "\(Int(balance))"
        return "\(amount) left · used after the plan limit"
    }
}

enum APIValueDisplay {
    static let help = "What this usage would cost at pay-per-use API prices. Your plan is a flat subscription, so this is not money you spent."

    static func split(_ text: String) -> (dollars: [String], tokens: [String]) {
        let parts = text.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (parts.filter { $0.contains("$") }, parts.filter { !$0.contains("$") })
    }
}

private struct WindowItem: Identifiable {
    let id: String
    let title: String
    let used: Double?
    let reset: String?
    let resetAt: String?
    let state: String?
    let reason: String?
}

private struct DriverRow: View {
    let percent: Double; let color: Color; let label: String; let note: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(color).frame(width: 34, alignment: .leading)
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(HUD.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .help(note?.isEmpty == false ? note! : "\(Int(percent.rounded()))% of recent usage: \(label)")
    }
}

// MARK: - Credit pool (kept from original, restyled)

private struct CreditPoolCard: View {
    let credit: CreditPoolState
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(credit.displayName).font(.system(size: 12, weight: .bold))
                Spacer()
                Text(remaining).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(HUD.ink)
            }
            if let pct = credit.remainingPercent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(HUD.track)
                        Capsule().fill(HUD.go.opacity(0.85))
                            .frame(width: max(4, geo.size.width * min(max(pct, 0), 100) / 100))
                    }
                }.frame(height: 6)
            }
            if let guardrail = credit.guardrail, !guardrail.isEmpty {
                Text(guardrail).font(.system(size: 10.5, weight: .medium)).foregroundStyle(HUD.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUD.go.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HUD.go.opacity(0.20), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var remaining: String {
        if let r = credit.remainingCredits {
            let c = formatCreditNumber(r)
            if let usd = credit.estimatedUSDRemaining { return "\(c) credits · \(String(format: "$%.0f", usd))" }
            return "\(c) credits"
        }
        return "entered by hand"
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var state: UsageState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: {
                    NotificationCenter.default.post(name: .usageHUDOpenActivity, object: nil)
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(HUD.ink2)
                        Text("Activity")
                            .foregroundStyle(HUD.ink2)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("usage.activity")
                .help("Sessions from today and the last 5 hours: project, model, tokens, API value and how fast each one is spending.")
                if state.loadError != nil {
                    HStack(spacing: 5) {
                        Circle().fill(HUD.slow).frame(width: 6, height: 6)
                        Text("Couldn't read usage")
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(HUD.slow)
                }
                Spacer(minLength: 4)
                Button(action: {
                    NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil,
                                                    userInfo: ["pane": SettingsPane.help.rawValue])
                }) {
                    Label("Help", systemImage: "questionmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HUD.ink2)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("usage.help")
                .help("Health check, updates and contacting support")
                Button(action: {
                    NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil)
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(HUD.ink2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .help("Settings: lanes, reset pings and background refresh")
                Button(action: { state.forceBudgetRefresh() }) {
                    HStack(spacing: 4) {
                        if state.isManualRefreshing {
                            ProgressView().controlSize(.mini)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HUD.ink)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(HUD.hair, lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.isManualRefreshing || state.setupBusy)
                .accessibilityIdentifier("usage.refresh")
                .accessibilityLabel(state.isManualRefreshing ? "Refreshing usage" : "Refresh usage")
                .help("Check every lane for a new reading now. Some providers only allow a check every few minutes.")
            }
            if let feedback = state.manualRefreshFeedback, feedback.needsAttention, !state.isManualRefreshing {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                    Text(feedback.title)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HUD.slow)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("usage.refresh.status")
                .accessibilityHint(feedback.detail)
                .help(feedback.detail)
            } else {
                statusLine
            }
        }
    }

    /// One quiet line beside the buttons: what the last check found and when.
    /// A refresh that needs attention gets its own amber line below instead.
    @ViewBuilder private var statusLine: some View {
        let feedback = state.manualRefreshFeedback
        Group {
            if state.isManualRefreshing {
                Text("Refreshing…")
            } else if let feedback, !feedback.needsAttention {
                (Text(feedback.title == "Updated" ? "Updated " : "\(feedback.title) · ")
                 + Text(feedback.checkedAt ?? state.lastLoadedAt ?? Date(), style: .time))
            } else if let loaded = state.lastLoadedAt {
                // "Checked", not "Updated": this is when the panel last
                // looked, not when any lane's number changed. Each lane
                // says its own age.
                (Text("Checked ") + Text(loaded, style: .time))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(HUD.ink3)
        .lineLimit(1)
        .truncationMode(.head)
        .help(feedback?.detail ?? "When the panel last checked for new readings. Each lane shows how current its own number is.")
        .accessibilityIdentifier(state.manualRefreshFeedback?.needsAttention == true ? "" : "usage.refresh.status")
    }
}

// MARK: - Value (API value vs what you pay)

/// Under the lanes: this week's usage at pay-per-use API prices beside
/// what the plans cost. API value is always labeled as not billed; with no
/// plan set it shows on its own, with a quiet way to set one.
private struct SpendValueLine: View {
    @ObservedObject var state: UsageState

    var body: some View {
        let visible = UsageInsights.visibleProviderOrder(snapshots: state.snapshots, budgets: state.budgets)
        if let line = SpendDisplay.valueLine(state.spend, visibleProviders: visible) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: LaneGrid.gap) {
                    Text(line.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HUD.ink2)
                        .lineLimit(1)
                        .padding(.leading, LaneGrid.nameText)
                        .frame(width: LaneGrid.name, alignment: .leading)
                    if let value = line.value {
                        (Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(HUD.ink)
                         + Text(" API value · \(SpendDisplay.notBilled)").font(.system(size: 11, weight: .medium)).foregroundStyle(HUD.ink3))
                            .monospacedDigit()
                            .lineLimit(1)
                    } else {
                        Text("Reading session logs…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HUD.ink3)
                    }
                    Spacer(minLength: 0)
                }
                if line.value != nil, line.paid != nil || line.showSetPlan {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let paid = line.paid {
                            (Text(paid).foregroundStyle(HUD.ink2)
                             + Text(line.multiple.map { " · \($0)" } ?? "").foregroundStyle(HUD.ink).fontWeight(.semibold))
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        if line.showSetPlan {
                            if line.paid != nil { Text("·").font(.system(size: 10.5)).foregroundStyle(HUD.ink3) }
                            SetPlanLink()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, LaneGrid.subLead)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(HUD.hairSoft).frame(height: 0.5) }
            .help(line.help)
        }
    }
}

/// "Set your plan": opens Settings on the Plans tab.
private struct SetPlanLink: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil,
                                            userInfo: ["pane": SettingsPane.plans.rawValue])
        } label: {
            Text("Set your plan")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(HUD.ink2)
                .underline(true, color: HUD.ink3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings on the Plans tab")
    }
}

// MARK: - Small shared pieces

private struct SectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(HUD.ink3)
    }
}

/// The fixed-gutter eyebrow label on a detail-card row (WINDOWS / SOURCE / SPEND…).
/// Lighter weight + wider tracking than the old heavy keys, so a stack of rows
/// reads as a refined spec list instead of a debug-log column.
/// Where a lane's number came from, as quiet text under its percentage.
/// The panel's claim is that every number carries its provenance without
/// expanding anything, but six glowing pills drowned the numbers, so this is
/// muted text: a small seal for official readings, amber only when a
/// reading stopped refreshing ("old") and describes the past.
private struct TrustTag: View {
    let trust: UsageInsights.LaneTrust

    var body: some View {
        HStack(spacing: 3) {
            if trust.level == "official", trust.isLive {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(HUD.go.opacity(0.8))
            }
            Text(trust.tagText)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(!trust.isGap && !trust.isLive ? HUD.watch.opacity(0.9) : HUD.ink3)
        .lineLimit(1)
        .fixedSize()
        .help(trust.help)
    }
}

private struct RowKey: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(HUD.ink3)
            .lineLimit(1)
            .frame(width: 64, alignment: .leading)
    }
}

private struct PillButton: View {
    let title: String; let system: String; let tint: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HUD.ink)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(tint)
                .clipShape(Capsule())
        }.buttonStyle(.plain)
    }
}

/// Status dot with a still halo. It used to pulse forever, and that endless
/// animation redrew the whole panel every frame: 20-35% CPU while open.
private struct BreathingDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.25)).frame(width: 12, height: 12))
    }
}

/// The app's own icon in the header. A bundled app shows its real icon
/// (three glass lane bars with the pace tick on graphite); `swift run` and
/// snapshot renders have no bundle icon, so they draw the same mark.
private struct AppMark: View {
    var body: some View {
        GeometryReader { geo in
            if let icon = Self.bundleIcon {
                // The system icon carries the standard margin around its
                // tile; scale it so the tile itself fills the frame, as the
                // drawn mark does.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geo.size.width * 1024 / 824, height: geo.size.height * 1024 / 824)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            } else {
                LaneBarsMark()
            }
        }
        .accessibilityHidden(true)
    }

    /// Only a real .app with an icon declared in its Info.plist; otherwise
    /// AppKit hands back the generic app icon.
    static let bundleIcon: NSImage? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["CFBundleIconName"] != nil || info["CFBundleIconFile"] != nil else { return nil }
        return NSApp?.applicationIconImage
    }()
}

/// The app icon drawn in SwiftUI, from the icon's own geometry
/// (Resources/AppIcon.icon, a 1024 canvas): three lanes on graphite, coral,
/// teal and indigo, each crossed by the white pace tick.
private struct LaneBarsMark: View {
    private struct Bar { let y: CGFloat; let width: CGFloat; let top: Color; let bottom: Color }
    private static let bars: [Bar] = [
        Bar(y: 201.3, width: 551.8, top: Color(hex: 0xFFA271), bottom: Color(hex: 0xE8643F)),
        Bar(y: 439.9, width: 223.7, top: Color(hex: 0x7FE9CD), bottom: Color(hex: 0x2FAE8E)),
        Bar(y: 678.5, width: 417.6, top: Color(hex: 0x9FA6FF), bottom: Color(hex: 0x5A62E6)),
    ]

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 1024
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 230 * s, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x2F3B36), Color(hex: 0x0F1412)],
                                         startPoint: .top, endPoint: .bottom))
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                    Capsule()
                        .fill(Color.black.opacity(0.36))
                        .frame(width: 745.6 * s, height: 144.2 * s)
                        .offset(x: 139.2 * s, y: bar.y * s)
                    Capsule()
                        .fill(LinearGradient(colors: [bar.top, bar.bottom], startPoint: .top, endPoint: .bottom))
                        .frame(width: bar.width * s, height: 144.2 * s)
                        .offset(x: 139.2 * s, y: bar.y * s)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(1, 24 * s), height: 194.2 * s)
                        .offset(x: 455.3 * s, y: (bar.y - 25) * s)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 230 * s, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
    }
}

private struct SetupCardView: View {
    @ObservedObject var state: UsageState

    var body: some View {
        let card = state.setupCard
        VStack(alignment: .leading, spacing: 10) {
            if card.phase == .doneWithData {
                HStack(spacing: 8) {
                    Image(systemName: card.needsAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(card.needsAttention ? HUD.watch : HUD.go)
                    Text(card.heading)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HUD.ink)
                    Spacer(minLength: 0)
                }
                ForEach(card.lanes) { lane in
                    LaneSetupRow(lane: lane, spinning: false)
                }
                if card.needsAttention {
                    Text("You can use the ready tools now. Follow the step shown for any reading that needs attention.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HUD.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !card.needsAttention {
                    Text(noWidow(card.trustLine))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HUD.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil, userInfo: ["pane": SettingsPane.agents.rawValue])
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal")
                            Text("Optional: connect your AI agents")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HUD.go)
                    }
                    .buttonStyle(.plain)
                    .help("Copy a prompt that connects Claude Code, Codex and Gemini CLI to Usage HUD")
                }
            } else {
                Text(card.heading)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HUD.ink)
                if let found = card.foundLine {
                    Text(found)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HUD.ink2)
                }
                if card.missingLine != nil, card.phase == .prompt {
                    Text("Only the tools you use need to be connected.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HUD.ink3)
                }
                if let note = card.runtimeNote {
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HUD.watch)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if card.phase == .running || card.phase == .doneWithNoData {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(card.lanes) { lane in
                            LaneSetupRow(lane: lane, spinning: card.phase == .running && !lane.status.isFinished)
                        }
                    }
                    .padding(.top, 2)
                }
                if card.phase == .prompt {
                    Button(action: { state.runSetup() }) {
                        Text(card.buttonTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.86))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(HUD.go)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.setupBusy)
                    Text(noWidow(card.buttonSubtext))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HUD.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(noWidow(card.trustLine))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HUD.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if card.phase != .running {
                HStack {
                    Button("Get help") {
                        NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil,
                                                        userInfo: ["pane": SettingsPane.help.rawValue])
                    }
                    .accessibilityIdentifier("setup.help")
                    Spacer()
                    if card.phase == .doneWithData || card.phase == .doneWithNoData {
                        Button("Got it") { state.dismissSetupSummary() }
                            .accessibilityIdentifier("setup.dismiss")
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUD.cardFill)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HUD.cardStroke, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct LaneSetupRow: View {
    let lane: LaneSetupResult
    var spinning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            }
            Text(lane.line)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HUD.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct EmptyLaneRow: View {
    let provider: String
    var body: some View {
        // Same grid as the live lanes: the name holds its column and the
        // one thing to do sits where the bar would be.
        HStack(alignment: .firstTextBaseline, spacing: LaneGrid.gap) {
            LaneName(title: laneTitle(provider), dot: HUD.provider(provider).opacity(0.35))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(line)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(HUD.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(UsageInsights.label(for: provider)), no reading yet. \(line)")
    }

    private var line: String { EmptyLaneCopy.line(for: provider) }
}

private struct EmptyUsageView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing shown yet").font(.system(size: 14, weight: .bold))
            Text("Turn on a tool in Settings to see its usage here.").font(.system(size: 11, weight: .medium)).foregroundStyle(HUD.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(40)
    }
}

// MARK: - Verdict / binding-constraint model

private struct ModeStyle {
    let raw: String
    init(_ mode: String) { self.raw = mode.lowercased() }

    var color: Color {
        switch raw {
        case "green": return HUD.go
        case "yellow": return HUD.watch
        case "orange": return HUD.slow
        case "red": return HUD.stop
        case "freeze": return HUD.freeze
        case "check": return HUD.ink3
        default: return HUD.wait
        }
    }
    var onColor: Color { raw == "yellow" ? .black : Color(hex: 0x06231A) }
    var icon: String {
        switch raw {
        case "green": return "bolt.fill"
        case "yellow": return "eye.fill"
        case "orange": return "exclamationmark.triangle.fill"
        case "red": return "hand.raised.fill"
        case "freeze": return "snowflake"
        case "check": return "questionmark.circle.fill"
        default: return "clock.fill"
        }
    }
    var word: String {
        switch raw {
        case "green": return "GO"
        case "yellow": return "WATCH"
        case "orange": return "SLOW"
        case "red": return "STOP"
        case "freeze": return "FREEZE"
        case "check": return "CHECK"
        default: return "WAIT"
        }
    }
    /// What VoiceOver says for the pill word.
    var spokenWord: String {
        switch raw {
        case "green": return "Go"
        case "yellow": return "Watch"
        case "orange": return "Slow down"
        case "red": return "Stop"
        case "freeze": return "Out until reset"
        case "check": return "Check"
        default: return "Waiting"
        }
    }

    var reassure: String {
        switch raw {
        case "green": return "This lane has room. The other lanes below have their own numbers."
        case "yellow": return "You're using this lane faster than its limit lasts. Keep sessions short."
        case "orange": return "Save this lane for work that matters most."
        case "red": return "Nearly out. Save what's left for work that can't wait."
        case "freeze": return "Out until the reset. Use another lane until then."
        case "check": return "This lane's reading isn't current. Refresh before trusting the verdict."
        default: return "Waiting for a reading after the reset."
        }
    }
}

private struct Binding {
    let provider: String
    let headroom: Double
    let title: String       // "Claude 5-hour"
    let resetLabel: String?
}

private func bindingConstraint(_ snapshots: [UsageSnapshot]) -> Binding? {
    var worst: (provider: String, used: Double, title: String, reset: String?)?
    for snap in snapshots {
        let name = UsageInsights.label(for: snap.provider)
        let pid = snap.provider.lowercased()
        if let s = snap.currentSession, let used = s.usedPct {
            if worst == nil || used > worst!.used {
                worst = (pid, used, "\(name) \(shortWindowTitle(snap, isSession: true))", s.resetLabel)
            }
        }
        if let w = snap.week, let used = w.usedPct {
            if worst == nil || used > worst!.used {
                worst = (pid, used, "\(name) \(shortWindowTitle(snap, isSession: false))", w.resetLabel)
            }
        }
    }
    guard let worst else { return nil }
    return Binding(provider: worst.provider, headroom: max(0, 100 - worst.used), title: worst.title, resetLabel: worst.reset)
}

private func shortWindowTitle(_ snapshot: UsageSnapshot, isSession: Bool) -> String {
    if isSession { return "5-hour" }
    return snapshot.provider.lowercased() == "gemini" ? "Quota" : "Weekly"
}

/// Lead with Claude (the usual headline lane), then Codex, Gemini, Grok, Local.
private func presentationSorted(_ providers: [String]) -> [String] {
    let priority = ["claude", "codex", "gemini", "grok", "local"]
    return providers.sorted {
        (priority.firstIndex(of: $0) ?? 99) < (priority.firstIndex(of: $1) ?? 99)
    }
}

// MARK: - Snapshot mode (offscreen PNG render for design verification)

enum SnapshotMode {
    /// When true, gauges/dots render their settled state with no animation so an
    /// offscreen capture is deterministic. Set by the --snapshot CLI path.
    static var enabled = false
    /// Optional taller frame so an offscreen capture can show the full scroll
    /// (details below the fold) in one image. nil = real panel height.
    static var height: CGFloat?
    /// Render the collapsed (details hidden) state instead of the default
    /// expanded snapshot.
    static var collapsed = false
}

// MARK: - Design tokens (map 1:1 to the design-lab prototype)

private enum HUD {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16

    static let base = Color(hex: 0x15171D)
    static let ink = Color(hex: 0xF3F4F8)
    static let ink2 = Color(hex: 0xF3F4F8, alpha: 0.72)
    static let ink3 = Color(hex: 0xF3F4F8, alpha: 0.52)
    static let hair = Color.white.opacity(0.09)
    static let hairSoft = Color.white.opacity(0.06)
    static let track = Color.white.opacity(0.08)

    // Card material: a faint top-lit gradient + a slightly brighter hairline so
    // surfaces read as raised glass instead of flat 3%-white rectangles.
    static let cardStroke = Color.white.opacity(0.11)
    static var cardFill: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)],
                       startPoint: .top, endPoint: .bottom)
    }

    static let go = Color(hex: 0x3DDC97)
    static let watch = Color(hex: 0xFBBF24)
    static let slow = Color(hex: 0xFB923C)
    static let stop = Color(hex: 0xF87171)
    static let freeze = Color(hex: 0xA78BFA)
    static let wait = Color(hex: 0x8A8F98)

    static let claude = Color(hex: 0xE07A5B)
    static let fable = Color(hex: 0xF06A6A)
    static let codex = Color(hex: 0x5FD3C4)
    static let gemini = Color(hex: 0x6F8BF5)
    static let gemini2 = Color(hex: 0xA472EF)
    static let grok = Color(hex: 0xD7DBE2)
    static let local = Color(hex: 0x4AC5D9)

    static func provider(_ id: String) -> Color {
        switch id.lowercased() {
        case "claude": return claude
        case "codex": return codex
        case "gemini": return gemini
        case "grok": return grok
        case "local": return local
        default: return ink2
        }
    }

    static func usedColor(_ used: Double) -> Color {
        let v = used.isFinite ? used : 0
        if v >= 90 { return stop }
        if v >= 75 { return slow }
        if v >= 55 { return watch }
        return go
    }

    /// Color for a "remaining/headroom" value (higher = healthier).
    static func remainColor(_ remaining: Double) -> Color {
        let v = remaining.isFinite ? remaining : 0
        if v <= 10 { return stop }
        if v <= 25 { return slow }
        if v <= 45 { return watch }
        return go
    }

    static func freshness(_ f: SourceFreshness) -> Color {
        switch f.state {
        case "live", "fresh": return go
        case "aging", "unknown": return watch
        case "stale": return slow
        case "missing": return stop
        default: return ink3
        }
    }

    /// Colour for a confidence level. Reuses the semantic ramp rather than
    /// introducing a second vocabulary: provenance you can lean on reads green,
    /// a derived number reads amber, an undeclared one reads grey.
    static func trust(_ level: String) -> Color {
        switch level {
        case "official": return go
        case "high": return local
        case "medium": return watch
        case "manual": return slow
        default: return wait
        }
    }
}

private extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Formatters

func formatPercent(_ value: Double) -> String {
    StatusItemText.percent(value)
}

private func formatInt(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
}

private func compactTokenCount(_ value: Int) -> String {
    formatInt(value).replacingOccurrences(of: "k", with: "K")
}

private func formatCreditNumber(_ value: Double) -> String {
    if value.rounded() == value { return formatInt(Int(value)) }
    return String(format: "%.1f", value)
}

private func relative(_ date: Date) -> String {
    let elapsed = max(0, Int(Date().timeIntervalSince(date)))
    if elapsed < 2 { return "now" }
    if elapsed < 60 { return "\(elapsed)s ago" }
    if elapsed < 3600 { return "\(elapsed / 60)m ago" }
    return "\(elapsed / 3600)h ago"
}

/// Keeps the last three words of a wrapping sentence together, so a line
/// never ends on one stray word ("About" / "10 seconds.").
func noWidow(_ text: String) -> String {
    var words = text.components(separatedBy: " ")
    guard words.count > 4 else { return text }
    let tail = words.suffix(3).joined(separator: "\u{00A0}")
    words.removeLast(3)
    return (words + [tail]).joined(separator: " ")
}

private func timeOnly(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: d)
}
