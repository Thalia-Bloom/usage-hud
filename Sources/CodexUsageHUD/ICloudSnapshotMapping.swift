import Foundation

extension ICloudUsageSnapshot {
    static func make(snapshots: [UsageSnapshot], selection: ProviderSelection, mac: String,
                     now: Date = Date()) -> ICloudUsageSnapshot {
        let providers = ProviderCatalog.displayProviders.filter { selection.includes($0.id) }.map { definition in
            let snapshot = snapshots.first { $0.provider.lowercased() == definition.id }
            var windows: [Window] = []
            if let snapshot {
                func add(_ metric: UsageSnapshot.WindowMetric?, label: String) {
                    guard let metric else { return }
                    let read = UsageInsights.parseDate(metric.eventAt)
                        ?? UsageInsights.parseDate(metric.capturedAt)
                        ?? UsageInsights.readingDate(snapshot)
                    // A fresh writer timestamp cannot freshen an old window.
                    let captured = UsageInsights.capturedDate(snapshot)
                    let readAt = [read, captured].compactMap { $0 }.min()
                    windows.append(.make(label: label, usedPct: metric.displayUsedPct,
                        resetAt: UsageInsights.parseDate(metric.resetAt), readAt: readAt, now: now,
                        forceOld: metric.isExpired || metric.isUnknown || UsageInsights.laneFreshness(for: snapshot, now: now).state != .live))
                }
                add(snapshot.currentSession, label: "5 hours")
                add(snapshot.week, label: "Week")
                add(snapshot.weekFable, label: "Fable week")
                // Providers with named custom quotas use windows instead of the two standard slots.
                if windows.isEmpty {
                    for (index, metric) in snapshot.windows.enumerated() {
                        add(metric, label: "Window \(index + 1)")
                    }
                }
            }
            if windows.isEmpty {
                windows = [.make(label: "Usage", usedPct: nil, resetAt: nil, readAt: nil, now: now)]
            }
            return Provider(id: definition.id, name: definition.name, windows: windows)
        }
        return ICloudUsageSnapshot(writtenAt: Int64(now.timeIntervalSince1970), mac: String(mac.prefix(48)), providers: providers)
    }
}
