import Foundation

/// Finds a usable claude CLI binary (>= 2.x) and remembers it.
///
/// Probe order is load-bearing: `~/.local/bin/claude` (native installer) comes
/// FIRST and the login-shell `which claude` comes LAST — on this machine the
/// login shell resolves to a stale 1.0.113 homebrew npm install while the real
/// 2.1.200 CLI lives in ~/.local/bin. Every candidate is validated by running
/// `--version` and requiring major >= 2 before it is trusted.
/// @unchecked: UserDefaults is documented thread-safe but this SDK does not
/// mark it Sendable.
struct ClaudeBinaryLocator: @unchecked Sendable {
    struct Binary: Equatable, Sendable {
        var path: String
        var version: String
    }

    static let pathDefaultsKey = "voxi.claude.path"
    static let versionDefaultsKey = "voxi.claude.version"
    static let requiredMajorVersion = 2

    static var defaultProbePaths: [String] {
        [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    private let defaults: UserDefaults
    private let probePaths: [String]
    private let versionOutput: @Sendable (String) -> String?
    private let loginShellLookup: @Sendable () -> String?
    private let fileExists: @Sendable (String) -> Bool

    init(
        defaults: UserDefaults = .standard,
        probePaths: [String] = ClaudeBinaryLocator.defaultProbePaths,
        versionOutput: @escaping @Sendable (String) -> String? = ClaudeBinaryLocator.runVersionCommand,
        loginShellLookup: @escaping @Sendable () -> String? = ClaudeBinaryLocator.loginShellWhichClaude,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.defaults = defaults
        self.probePaths = probePaths
        self.versionOutput = versionOutput
        self.loginShellLookup = loginShellLookup
        self.fileExists = fileExists
    }

    /// Persisted binary from a previous probe, if it still exists on disk.
    func cached() -> Binary? {
        guard
            let path = defaults.string(forKey: Self.pathDefaultsKey),
            let version = defaults.string(forKey: Self.versionDefaultsKey),
            fileExists(path)
        else { return nil }
        return Binary(path: path, version: version)
    }

    /// Cached binary if available, else a fresh probe.
    func locate() -> Binary? {
        cached() ?? probe()
    }

    /// Full probe: walk the known install paths first, fall back to the login
    /// shell's `which claude` last. Persists (and returns) the first candidate
    /// whose `--version` reports major >= 2.
    @discardableResult
    func probe() -> Binary? {
        var candidates = probePaths
        if let shellPath = loginShellLookup(), !candidates.contains(shellPath) {
            candidates.append(shellPath)
        }
        for path in candidates where fileExists(path) {
            guard
                let output = versionOutput(path),
                let parsed = Self.parseVersion(output),
                parsed.major >= Self.requiredMajorVersion
            else { continue }
            let binary = Binary(path: path, version: parsed.display)
            defaults.set(binary.path, forKey: Self.pathDefaultsKey)
            defaults.set(binary.version, forKey: Self.versionDefaultsKey)
            return binary
        }
        return nil
    }

    /// Parses `claude --version` output like "2.1.200 (Claude Code)".
    static func parseVersion(_ output: String) -> (major: Int, display: String)? {
        for token in output.split(whereSeparator: \.isWhitespace) {
            let parts = token.split(separator: ".")
            guard parts.count >= 2, let major = Int(parts[0]), Int(parts[1]) != nil else { continue }
            return (major, String(token))
        }
        return nil
    }

    // MARK: - Real process probes

    static func runVersionCommand(at path: String) -> String? {
        runForOutput(executable: path, arguments: ["--version"])
    }

    static func loginShellWhichClaude() -> String? {
        guard let output = runForOutput(executable: "/bin/zsh", arguments: ["-lc", "which claude"]) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    private static func runForOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
