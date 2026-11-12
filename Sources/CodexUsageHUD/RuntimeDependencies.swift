import Foundation

/// Resolves Node.js the way `bin/bloom-node` does, and Python 3 via PATH
/// plus Homebrew well-known paths. Never installs anything.
enum RuntimeDependencies {
    struct Probe: Equatable {
        var env: [String: String]
        var home: URL
        var extraNodeCandidates: [URL]
        var extraPythonCandidates: [URL]
        var scanNvm: Bool
        var scanVolta: Bool
        /// `/usr/bin/python3` is only a real interpreter once the Command
        /// Line Tools are installed; otherwise it is a stub that pops an
        /// install dialog the first time it runs. This mirrors
        /// `xcode-select -p` without shelling out on every probe.
        var commandLineToolsInstalled: () -> Bool

        static func live(env: [String: String] = ProcessInfo.processInfo.environment, home: URL = UsagePaths.home) -> Probe {
            Probe(
                env: env,
                home: home,
                extraNodeCandidates: [
                    URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                    URL(fileURLWithPath: "/usr/local/bin/node"),
                ],
                extraPythonCandidates: [
                    URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
                    URL(fileURLWithPath: "/usr/local/bin/python3"),
                    URL(fileURLWithPath: "/usr/bin/python3"),
                ],
                scanNvm: true,
                scanVolta: true,
                commandLineToolsInstalled: RuntimeDependencies.probeCommandLineTools
            )
        }

        /// Isolated probe for tests: only PATH and the candidates the caller supplies.
        static func isolated(
            env: [String: String],
            home: URL,
            extraNode: [URL] = [],
            extraPython: [URL] = [],
            commandLineToolsInstalled: @escaping () -> Bool = { true }
        ) -> Probe {
            Probe(
                env: env,
                home: home,
                extraNodeCandidates: extraNode,
                extraPythonCandidates: extraPython,
                scanNvm: false,
                scanVolta: false,
                commandLineToolsInstalled: commandLineToolsInstalled
            )
        }

        static func == (lhs: Probe, rhs: Probe) -> Bool {
            lhs.env == rhs.env
                && lhs.home == rhs.home
                && lhs.extraNodeCandidates == rhs.extraNodeCandidates
                && lhs.extraPythonCandidates == rhs.extraPythonCandidates
                && lhs.scanNvm == rhs.scanNvm
                && lhs.scanVolta == rhs.scanVolta
        }
    }

    static var nodeAvailable: Bool { resolveNode() != nil }
    static var python3Available: Bool { resolvePython3() != nil }

    static func resolveNode(probe: Probe = .live(), fileManager: FileManager = .default) -> URL? {
        if let override = probe.env["BLOOM_NODE_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        if let found = which("node", path: probe.env["PATH"] ?? "", fileManager: fileManager) {
            return found
        }
        for candidate in probe.extraNodeCandidates {
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if probe.scanNvm, let nvm = newestNvmNode(home: probe.home, fileManager: fileManager) {
            return nvm
        }
        if probe.scanVolta {
            let volta = probe.home.appendingPathComponent(".volta/bin/node")
            if fileManager.isExecutableFile(atPath: volta.path) { return volta }
        }
        return nil
    }

    static func resolvePython3(probe: Probe = .live(), fileManager: FileManager = .default) -> URL? {
        // `/usr/bin/env python3` is a PATH lookup.
        if let found = which("python3", path: probe.env["PATH"] ?? "", fileManager: fileManager),
           isUsablePython3(found, probe: probe, fileManager: fileManager) {
            return found
        }
        for candidate in probe.extraPythonCandidates {
            if fileManager.isExecutableFile(atPath: candidate.path), isUsablePython3(candidate, probe: probe, fileManager: fileManager) {
                return candidate
            }
        }
        return nil
    }

    /// `/usr/bin/python3` is only a real interpreter once the Command Line
    /// Tools are installed; without them it's a stub that pops an install
    /// dialog the first time it runs. Every other python3 path is fine.
    static func isUsablePython3(_ url: URL, probe: Probe, fileManager: FileManager) -> Bool {
        guard url.path == "/usr/bin/python3" else { return true }
        return probe.commandLineToolsInstalled()
    }

    static func probeCommandLineTools() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    static var commandLineToolsInstalled: Bool { probeCommandLineTools() }

    static let nodeInstallHint = "Install Node.js 18+ from nodejs.org or Homebrew"

    static func which(_ name: String, path: String, fileManager: FileManager = .default) -> URL? {
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func newestNvmNode(home: URL, fileManager: FileManager) -> URL? {
        let versions = home.appendingPathComponent(".nvm/versions/node")
        guard let names = try? fileManager.contentsOfDirectory(atPath: versions.path), !names.isEmpty else {
            return nil
        }
        let newest = names.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
        guard let newest else { return nil }
        let candidate = versions.appendingPathComponent(newest).appendingPathComponent("bin/node")
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}
