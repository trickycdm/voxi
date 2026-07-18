import AppKit
import Carbon.HIToolbox
import IOKit

/// Decides whether secure event input should block an insertion.
///
/// `IsSecureEventInputEnabled()` is machine-global: corporate endpoint/MDM
/// agents commonly hold it for the whole session, which must not disable
/// dictation into ordinary fields. WindowServer records the holder's PID in
/// the IORegistry root's `IOConsoleUsers` property, so insertion is refused
/// only when the holder is the app being inserted into (a real password
/// prompt, or Terminal's Secure Keyboard Entry) — or when the holder cannot
/// be identified at all.
enum SecureInput {
    struct Holder: Equatable, Sendable {
        var pid: pid_t
        var bundleID: String?
        var name: String?
    }

    enum Verdict: Equatable, Sendable {
        case allow
        /// The insertion target itself holds secure input.
        case heldByTarget(holderName: String?)
        /// The flag is set but no holder is identifiable — refuse.
        case heldByUnknown
    }

    @MainActor
    static func evaluate(targetPID: pid_t, targetBundleID: String?) -> Verdict {
        verdict(
            secureInputEnabled: IsSecureEventInputEnabled(),
            holders: currentHolders(),
            targetPID: targetPID,
            targetBundleID: targetBundleID)
    }

    /// Pure decision; unit-tested.
    static func verdict(
        secureInputEnabled: Bool,
        holders: [Holder],
        targetPID: pid_t,
        targetBundleID: String?
    ) -> Verdict {
        guard secureInputEnabled else { return .allow }
        guard !holders.isEmpty else { return .heldByUnknown }
        // Bundle match covers holds taken by a helper process of the target
        // (browsers take the hold from a subprocess, not the main app PID).
        if let match = holders.first(where: {
            $0.pid == targetPID || ($0.bundleID != nil && $0.bundleID == targetBundleID)
        }) {
            return .heldByTarget(holderName: match.name ?? match.bundleID)
        }
        return .allow
    }

    /// Processes currently holding secure event input, per WindowServer's
    /// console-session records. The PID is attributed to the *responsible*
    /// app (a browser helper's hold reports the browser), which is what the
    /// target match wants. Daemons without a bundle resolve to pid-only.
    /// Must be `IORegistryGetRootEntry` — `IORegistryEntryFromPath("IOService:/")`
    /// resolves to a different entry that lacks `IOConsoleUsers`.
    @MainActor
    static func currentHolders() -> [Holder] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != MACH_PORT_NULL else { return [] }
        defer { IOObjectRelease(root) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return [] }

        return sessions.compactMap { session in
            guard let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
            else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return Holder(pid: pid, bundleID: app?.bundleIdentifier, name: app?.localizedName)
        }
    }
}
