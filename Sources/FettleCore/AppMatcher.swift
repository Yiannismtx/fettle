import Foundation

/// An app bundle found in one of the Applications folders.
public struct InstalledApp: Hashable, Sendable {
    public let url: URL
    public let displayName: String
    public let bundleIdentifier: String?
    public let version: String?

    public var normalizedName: String { AppMatcher.normalize(displayName) }

    public init(url: URL, displayName: String, bundleIdentifier: String?, version: String?) {
        self.url = url
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }
}

/// How much to trust a filename → installed-app match.
///
/// Nothing here is certain (spec §6): the review step is what makes an imperfect
/// match safe, so the confidence is surfaced in the UI rather than hidden behind
/// a boolean.
public enum MatchConfidence: Int, Comparable, Sendable {
    case none = 0
    case weak = 1
    case strong = 2
    case exact = 3

    public static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .none: return "No match"
        case .weak: return "Possible match"
        case .strong: return "Likely match"
        case .exact: return "Installed"
        }
    }
}

public struct AppMatch: Hashable, Sendable {
    public let app: InstalledApp
    public let confidence: MatchConfidence

    public init(app: InstalledApp, confidence: MatchConfidence) {
        self.app = app
        self.confidence = confidence
    }
}

/// Fuzzy-matches an installer filename against the apps that are actually
/// installed, so Fettle can tell "installer for something you now have" from
/// "installer for something you never used".
public struct AppMatcher: Sendable {
    /// Where apps legitimately live. `/System/Applications` is excluded: those
    /// ship with macOS and are never what a downloaded installer produced.
    public static var defaultSearchDirectories: [URL] {
        var directories = [URL(fileURLWithPath: "/Applications")]
        let home = FileManager.default.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent("Applications"))
        directories.append(URL(fileURLWithPath: "/Applications/Utilities"))
        return directories
    }

    private let apps: [InstalledApp]

    public init(apps: [InstalledApp]) {
        self.apps = apps
    }

    public init(searchDirectories: [URL] = AppMatcher.defaultSearchDirectories) {
        self.apps = Self.findInstalledApps(in: searchDirectories)
    }

    public var installedApps: [InstalledApp] { apps }

    public static func findInstalledApps(in directories: [URL]) -> [InstalledApp] {
        let fm = FileManager.default
        var found: [URL: InstalledApp] = [:]

        for directory in directories {
            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                let standardized = url.standardizedFileURL
                guard found[standardized] == nil else { continue }
                let info = Bundle(url: url)?.infoDictionary
                let displayName = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                found[standardized] = InstalledApp(
                    url: url,
                    displayName: displayName,
                    bundleIdentifier: info?["CFBundleIdentifier"] as? String,
                    version: info?["CFBundleShortVersionString"] as? String
                )
            }
        }
        return found.values.sorted { $0.displayName < $1.displayName }
    }

    /// Tokens that describe the *download*, not the product, and so must not
    /// influence the match.
    private static let noiseTokens: Set<String> = [
        "installer", "install", "setup", "mac", "macos", "osx", "os", "x",
        "darwin", "universal", "arm64", "aarch64", "x8664", "x86", "amd64",
        "intel", "apple", "silicon", "app", "dmg", "pkg", "for", "the",
        "latest", "stable", "release", "final", "full", "offline", "web",
        "download", "edition", "bit", "64", "32", "beta", "rc", "nightly",
    ]

    /// Reduce a filename or app name to a comparable form: lowercase, no
    /// version numbers, no punctuation, no download noise.
    public static func normalize(_ raw: String) -> String {
        tokens(raw).joined()
    }

    /// The meaningful words of a name, in order.
    public static func tokens(_ raw: String) -> [String] {
        var name = raw
        // Drop a trailing extension, but only a real one — "Node.js" must not
        // lose "js".
        let knownExtensions: Set<String> = ["dmg", "pkg", "mpkg", "app", "zip", "iso"]
        let ext = (name as NSString).pathExtension.lowercased()
        if knownExtensions.contains(ext) {
            name = (name as NSString).deletingPathExtension
        }

        // Split on anything that isn't a letter or digit, and also at
        // lower→upper boundaries so "GoogleChrome" becomes two tokens.
        var pieces: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if character.isLetter || character.isNumber {
                if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { pieces.append(current) }

        return pieces.compactMap { piece -> String? in
            let lowered = piece.lowercased()
            // Pure numbers and version-shaped tokens are release metadata.
            if lowered.allSatisfy(\.isNumber) { return nil }
            if isVersionToken(lowered) { return nil }
            if noiseTokens.contains(lowered) { return nil }
            return lowered
        }
    }

    /// "v2", "2b3", "10rc1" — a token that is only a version.
    private static func isVersionToken(_ token: String) -> Bool {
        var body = token
        if body.hasPrefix("v"), body.dropFirst().first?.isNumber == true {
            body = String(body.dropFirst())
        }
        guard body.contains(where: \.isNumber) else { return false }
        // Version-ish if it is digits plus at most a short alphabetic tail.
        let letters = body.filter(\.isLetter)
        return letters.count <= 2
    }

    /// Best match for an installer filename, or nil when nothing is close enough.
    public func match(fileName: String) -> AppMatch? {
        let fileTokens = Self.tokens(fileName)
        guard !fileTokens.isEmpty else { return nil }
        let fileCompact = fileTokens.joined()

        var best: AppMatch?
        for app in apps {
            let appTokens = Self.tokens(app.displayName)
            guard !appTokens.isEmpty else { continue }
            let appCompact = appTokens.joined()

            let confidence = Self.confidence(
                fileTokens: fileTokens, fileCompact: fileCompact,
                appTokens: appTokens, appCompact: appCompact
            )
            guard confidence != .none else { continue }
            if best == nil || confidence > best!.confidence {
                best = AppMatch(app: app, confidence: confidence)
            }
            if confidence == .exact { break }
        }
        return best
    }

    static func confidence(
        fileTokens: [String], fileCompact: String,
        appTokens: [String], appCompact: String
    ) -> MatchConfidence {
        if fileCompact == appCompact { return .exact }

        // A one-word app name must not match on a substring alone: "Go" would
        // otherwise claim "GoLand", "Google Chrome" and "Gogs".
        let shorter = min(fileCompact.count, appCompact.count)
        let longer = max(fileCompact.count, appCompact.count)
        guard shorter >= 3 else { return .none }

        let fileSet = Set(fileTokens)
        let appSet = Set(appTokens)
        let shared = fileSet.intersection(appSet)

        if !shared.isEmpty {
            // Every word of the app's name appears in the filename — this is the
            // common "AppName 1.2.3.dmg" shape.
            if appSet.isSubset(of: fileSet) || fileSet.isSubset(of: appSet) {
                return .strong
            }
            let overlap = Double(shared.count) / Double(fileSet.union(appSet).count)
            if overlap >= 0.5 { return .strong }
            if overlap >= 0.34 { return .weak }
        }

        // Fall back to compact containment, guarded so a short name can't swallow
        // a long one.
        if fileCompact.contains(appCompact) || appCompact.contains(fileCompact) {
            let ratio = Double(shorter) / Double(longer)
            if ratio >= 0.75 { return .strong }
            if ratio >= 0.5 { return .weak }
        }

        return .none
    }
}
