import Foundation

/// Identity of a file's contents for cache purposes: path + mtime + size.
struct FileSignature: Hashable, Sendable {
    let path: String
    let modified: Double
    let size: Int

    init(path: String, modified: Double, size: Int) {
        self.path = path
        self.modified = modified
        self.size = size
    }

    init?(url: URL) {
        // A URL memoizes resource values; stat through a fresh one so a reused
        // URL instance still sees the file's current mtime and size.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        self.init(
            path: url.path,
            modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? 0
        )
    }
}

/// Thread-safe memo of a value derived from one file. The value is recomputed
/// only when the file's signature (path, mtime, size) changes. `loads` counts
/// real recomputations so tests can prove an unchanged file is not re-read.
final class FileSignatureCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (signature: FileSignature, value: Value)] = [:]
    private let limit: Int
    private var loadCount = 0

    init(limit: Int = 256) { self.limit = limit }

    var loads: Int {
        lock.lock(); defer { lock.unlock() }
        return loadCount
    }

    func value(for url: URL, compute: (URL) -> Value) -> Value {
        guard let signature = FileSignature(url: url) else { return compute(url) }
        lock.lock()
        if let hit = entries[url.path], hit.signature == signature {
            lock.unlock()
            return hit.value
        }
        lock.unlock()
        let value = compute(url)
        lock.lock()
        loadCount += 1
        if entries.count >= limit { entries.removeAll() }
        entries[url.path] = (signature, value)
        lock.unlock()
        return value
    }

    func removeAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
