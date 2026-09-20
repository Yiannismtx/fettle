import Foundation

/// Whether macOS will let this process read the user's protected folders.
public enum FullDiskAccessStatus: Equatable, Sendable {
    case granted
    case denied
    /// The probe file wasn't where it was expected. Reported as its own case
    /// rather than guessed at: claiming "denied" because a file is missing
    /// would send the user off to fix a permission that was never the problem.
    case unknown

    public var isGranted: Bool { self == .granted }
}

/// Finds out whether Fettle has Full Disk Access, and where to send the user
/// if it doesn't.
///
/// This matters far more for a malware scan than for anything else Fettle
/// does. Without Full Disk Access, macOS refuses clamscan's reads across
/// Desktop, Documents, Downloads, Mail and Messages — and clamscan does not
/// treat a refusal as a failure. It finishes, reports zero infected files, and
/// exits clean. A security tool that says "you're fine" after being prevented
/// from looking is worse than one that says nothing, so Fettle checks for
/// itself instead of trusting the exit code.
public enum FullDiskAccess {
    /// The TCC databases. Reading either one requires Full Disk Access and
    /// nothing else — which is what makes them the standard probe.
    static func probePaths(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
        ]
    }

    /// Opens the probe file rather than asking `access(2)` about it.
    ///
    /// TCC intercepts `open`, not `access`, so the permission check can say yes
    /// to a file the process cannot actually read. Opening it is the only
    /// answer that matches what clamscan will experience.
    public static func probe(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> FullDiskAccessStatus {
        probe(paths: probePaths(home: home))
    }

    /// The seam the tests drive. `probe(home:)` always consults the
    /// system-wide TCC database as well as the one in the home folder, which
    /// means it can't be given a temporary directory and told the truth about
    /// what's in it — the real `/Library` copy is still there.
    static func probe(paths: [URL]) -> FullDiskAccessStatus {
        var sawProbeFile = false
        for url in paths
        where FileManager.default.fileExists(atPath: url.path) {
            sawProbeFile = true
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.close()
                return .granted
            }
        }
        return sawProbeFile ? .denied : .unknown
    }

    /// Deep link to System Settings › Privacy & Security › Full Disk Access.
    ///
    /// Telling someone to "grant Full Disk Access in System Settings" is four
    /// levels of navigation and a search box; opening the pane is one click.
    public static var settingsPaneURL: URL {
        URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!
    }

    /// What to tell the user, given a plan that may or may not need this.
    ///
    /// A folder scan of somewhere unprotected doesn't need Full Disk Access at
    /// all, and nagging about it there would teach the user to dismiss the
    /// warning that matters.
    public static func advice(
        for plan: MalwareScanPlan,
        status: FullDiskAccessStatus,
        blocked: [ScanLocation]
    ) -> String? {
        guard !blocked.isEmpty || (status == .denied && plan.kind != .folder) else { return nil }

        if blocked.isEmpty {
            return "macOS is withholding Full Disk Access from Fettle. Some of this scan's "
                + "locations may be unreadable, and clamscan reports an unreadable folder as "
                + "clean rather than as an error."
        }

        let names = blocked.map(\.label)
        let listed = names.count <= 3
            ? Formatting.list(names)
            : "\(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more"
        return "macOS is blocking Fettle from reading \(listed). Those folders will be "
            + "reported as clean whether or not they are. Grant Full Disk Access to scan them."
    }
}
