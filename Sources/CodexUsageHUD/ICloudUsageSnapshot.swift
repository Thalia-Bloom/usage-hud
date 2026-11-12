import Foundation

/// Version 1 uses short JSON keys to keep all five providers below 1 KB.
/// No source snapshot is encoded: this is an explicit field allowlist.
struct ICloudUsageSnapshot: Codable, Equatable {
    var writtenAt: Int64
    var mac: String
    var providers: [Provider]
    enum CodingKeys: String, CodingKey { case writtenAt = "t", mac = "m", providers = "p" }

    struct Provider: Codable, Equatable {
        var id: String
        var name: String
        var windows: [Window]
        enum CodingKeys: String, CodingKey { case id = "i", name = "n", windows = "w" }
    }

    struct Window: Codable, Equatable {
        enum State: String, Codable { case live, old, missing }
        var label: String
        var usedPct: Double?
        var resetAt: Int64?
        var readAt: Int64?
        var state: State
        enum CodingKeys: String, CodingKey {
            case label = "l", usedPct = "u", resetAt = "r", readAt = "a", state = "s"
        }

        static func make(label: String, usedPct: Double?, resetAt: Date?, readAt: Date?,
                         now: Date, forceOld: Bool = false) -> Window {
            let pct = usedPct.flatMap { $0.isFinite && $0 >= 0 && $0 <= 100 ? ($0 * 10).rounded() / 10 : nil }
            let age = readAt.map { now.timeIntervalSince($0) }
            // The three-state wire format has no "recent". Conservatively old
            // after 10 minutes; never promote a panel's recent/old reading to live.
            let live = age.map { $0 >= 0 && $0 <= 600 } ?? false
            let expired = resetAt.map { $0 <= now } ?? false
            return Window(label: label, usedPct: pct, resetAt: resetAt.map { Int64($0.timeIntervalSince1970) },
                          readAt: readAt.map { Int64($0.timeIntervalSince1970) },
                          state: pct == nil ? .missing : (live && !expired && !forceOld ? .live : .old))
        }
    }

    enum EncodingError: Error { case tooLarge }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count < 1024 else { throw EncodingError.tooLarge }
        return data
    }
}

protocol ICloudSnapshotStore {
    func put(_ data: Data, forKey key: String)
    func remove(_ key: String)
    func synchronize() -> Bool
}

final class UbiquitousSnapshotStore: ICloudSnapshotStore {
    func put(_ data: Data, forKey key: String) { NSUbiquitousKeyValueStore.default.set(data, forKey: key) }
    func remove(_ key: String) { NSUbiquitousKeyValueStore.default.removeObject(forKey: key) }
    func synchronize() -> Bool { NSUbiquitousKeyValueStore.default.synchronize() }
}

/// Only the GUI's refresh path calls this. Tests inject an in-memory store.
final class ICloudSnapshotPublisher {
    static let key = "usage.snapshot.v1"
    static let preferenceKey = "usageHUD.showOnMobile"
    private let defaults: UserDefaults
    private let store: ICloudSnapshotStore
    private(set) var lastError: String?

    init(defaults: UserDefaults = .standard, store: ICloudSnapshotStore = UbiquitousSnapshotStore()) {
        self.defaults = defaults
        self.store = store
    }

    var enabled: Bool { defaults.bool(forKey: Self.preferenceKey) }

    func initializeAfterSetup(_ completed: Bool) {
        if completed && defaults.object(forKey: Self.preferenceKey) == nil {
            defaults.set(true, forKey: Self.preferenceKey)
        }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.preferenceKey)
        if !enabled {
            store.remove(Self.key)
            _ = store.synchronize()
        }
    }

    func publish(_ snapshot: ICloudUsageSnapshot) {
        guard enabled else { return }
        do {
            let data = try snapshot.encoded()
            store.put(data, forKey: Self.key)
            // synchronize asks the local store to sync; it does not prove delivery.
            _ = store.synchronize()
            lastError = nil
        } catch {
            // Do not leave an old payload looking like today's full set of lanes.
            store.remove(Self.key)
            _ = store.synchronize()
            lastError = "The usage snapshot is too large to share."
        }
    }
}
