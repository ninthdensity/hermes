import Foundation

public struct SemanticVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        // Strip build metadata (+...)
        let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count >= 2 && coreParts.count <= 3 else { return nil }

        var nums: [Int] = []
        for component in coreParts {
            guard !component.isEmpty, component.allSatisfy(\.isASCII), let value = Int(component), value >= 0 else {
                return nil
            }
            nums.append(value)
        }

        let prereleaseIDs: [String]
        if parts.count == 2 {
            let pre = String(parts[1])
            guard !pre.isEmpty else { return nil }
            let ids = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !ids.contains(where: \.isEmpty) else { return nil }
            prereleaseIDs = ids
        } else {
            prereleaseIDs = []
        }

        self.major = nums[0]
        self.minor = nums[1]
        self.patch = nums.count > 2 ? nums[2] : 0
        self.prerelease = prereleaseIDs
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A normal version has higher precedence than a pre-release version.
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<count {
            let a = lhs.prerelease[i]
            let b = rhs.prerelease[i]
            if a == b { continue }
            switch (Int(a), Int(b)) {
            case let (ai?, bi?): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public struct ReleaseAsset: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case zip
        case dmg
        case pkg
        case other
    }

    public let name: String
    public let downloadURL: URL
    public let size: Int64
    public let contentType: String

    public init(name: String, downloadURL: URL, size: Int64, contentType: String) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.contentType = contentType
    }

    public var kind: Kind {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".dmg") { return .dmg }
        if lower.hasSuffix(".pkg") { return .pkg }
        return .other
    }
}

public struct ReleaseInfo: Equatable, Hashable, Sendable {
    public let tagName: String
    public let version: SemanticVersion
    public let name: String
    public let notes: String
    public let htmlURL: URL
    public let publishedAt: String?
    public let isPrerelease: Bool
    public let isDraft: Bool
    public let assets: [ReleaseAsset]

    public init(
        tagName: String,
        version: SemanticVersion,
        name: String,
        notes: String,
        htmlURL: URL,
        publishedAt: String? = nil,
        isPrerelease: Bool = false,
        isDraft: Bool = false,
        assets: [ReleaseAsset] = []
    ) {
        self.tagName = tagName
        self.version = version
        self.name = name
        self.notes = notes
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.isDraft = isDraft
        self.assets = assets
    }

    /// Selects the best macOS installer/archive asset attached to the release.
    public var preferredDownloadAsset: ReleaseAsset? {
        let zips = assets.filter { $0.kind == .zip }
        if let macZip = zips.first(where: { Self.looksLikeMacAsset($0.name) }) {
            return macZip
        }
        if let anyZip = zips.first {
            return anyZip
        }
        if let dmg = assets.first(where: { $0.kind == .dmg }) {
            return dmg
        }
        if let pkg = assets.first(where: { $0.kind == .pkg }) {
            return pkg
        }
        return nil
    }

    private static func looksLikeMacAsset(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("mac") || lower.contains("darwin") || lower.contains("hermes")
            || lower.contains("arm64") || lower.contains("universal")
    }
}

public enum UpdateCheckOutcome: Equatable, Sendable {
    case updateAvailable(ReleaseInfo)
    case upToDate(currentVersion: SemanticVersion, latestVersion: SemanticVersion?)
}

public enum UpdateCheckerError: LocalizedError, Equatable, Sendable {
    case invalidRepository(String)
    case httpError(Int)
    case invalidResponse
    case networkError(String)
    case invalidAppBundle(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let repo):
            return "Invalid GitHub repository configuration: “\(repo)”."
        case .httpError(let status):
            return "GitHub returned HTTP \(status) while checking for updates."
        case .invalidResponse:
            return "Could not read the update information returned by GitHub."
        case .networkError(let message):
            return message
        case .invalidAppBundle(let reason):
            return "The downloaded update could not be verified: \(reason)"
        }
    }
}

public enum UpdateChecker {
    public static let defaultRepository = "ninthdensity/hermes"
    public static let defaultAutomaticCheckInterval: TimeInterval = 24 * 60 * 60

    public static func latestReleaseURL(forRepository repo: String) throws -> URL {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              components.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } }),
              let url = URL(string: "https://api.github.com/repos/\(trimmed)/releases/latest")
        else {
            throw UpdateCheckerError.invalidRepository(repo)
        }
        return url
    }

    public static func releasesPageURL(forRepository repo: String) -> URL {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: "https://github.com/\(trimmed)/releases")
            ?? URL(string: "https://github.com/\(defaultRepository)/releases")!
    }

    public static func parseGitHubRelease(data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
                let size: Int64
                let content_type: String?
            }

            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String
            let published_at: String?
            let prerelease: Bool?
            let draft: Bool?
            let assets: [Asset]?
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateCheckerError.invalidResponse
        }

        guard let version = SemanticVersion(payload.tag_name),
              let htmlURL = URL(string: payload.html_url),
              htmlURL.scheme?.lowercased() == "https"
        else {
            throw UpdateCheckerError.invalidResponse
        }

        let parsedAssets: [ReleaseAsset] = (payload.assets ?? []).compactMap { asset in
            guard let url = URL(string: asset.browser_download_url),
                  url.scheme?.lowercased() == "https"
            else {
                return nil
            }
            return ReleaseAsset(
                name: asset.name,
                downloadURL: url,
                size: asset.size,
                contentType: asset.content_type ?? "application/octet-stream"
            )
        }

        return ReleaseInfo(
            tagName: payload.tag_name,
            version: version,
            name: (payload.name?.isEmpty == false ? payload.name! : payload.tag_name),
            notes: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            htmlURL: htmlURL,
            publishedAt: payload.published_at,
            isPrerelease: payload.prerelease ?? false,
            isDraft: payload.draft ?? false,
            assets: parsedAssets
        )
    }

    public static func evaluate(
        release: ReleaseInfo,
        currentVersion: SemanticVersion,
        skippedVersion: String? = nil,
        includeSkipped: Bool = true
    ) -> UpdateCheckOutcome {
        if release.isDraft || release.isPrerelease || release.version.isPrerelease {
            return .upToDate(currentVersion: currentVersion, latestVersion: nil)
        }
        guard release.version > currentVersion else {
            return .upToDate(currentVersion: currentVersion, latestVersion: release.version)
        }
        if !includeSkipped, let skipped = skippedVersion, !skipped.isEmpty {
            if skipped == release.tagName || skipped == release.version.description {
                return .upToDate(currentVersion: currentVersion, latestVersion: release.version)
            }
            if let skippedSemver = SemanticVersion(skipped), skippedSemver == release.version {
                return .upToDate(currentVersion: currentVersion, latestVersion: release.version)
            }
        }
        return .updateAvailable(release)
    }

    public static func shouldPerformAutomaticCheck(
        lastCheckDate: Date?,
        now: Date = Date(),
        interval: TimeInterval = defaultAutomaticCheckInterval
    ) -> Bool {
        guard let lastCheckDate else { return true }
        return now.timeIntervalSince(lastCheckDate) >= interval
    }

    public static func fetchLatestRelease(
        repository: String,
        currentVersion: SemanticVersion,
        skippedVersion: String? = nil,
        includeSkipped: Bool = true,
        session: URLSession = .shared
    ) async throws -> UpdateCheckOutcome {
        let url = try latestReleaseURL(forRepository: repository)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Hermes/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckerError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckerError.invalidResponse
        }
        if http.statusCode == 404 {
            return .upToDate(currentVersion: currentVersion, latestVersion: nil)
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateCheckerError.httpError(http.statusCode)
        }

        let release = try parseGitHubRelease(data: data)
        return evaluate(
            release: release,
            currentVersion: currentVersion,
            skippedVersion: skippedVersion,
            includeSkipped: includeSkipped
        )
    }

    /// Validates that an extracted `.app` bundle has the expected bundle identifier and an executable binary.
    public static func validateExtractedAppBundle(at appURL: URL, expectedBundleIdentifier: String) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw UpdateCheckerError.invalidAppBundle("Missing or unreadable Info.plist.")
        }

        guard let bundleID = plist["CFBundleIdentifier"] as? String, bundleID == expectedBundleIdentifier else {
            throw UpdateCheckerError.invalidAppBundle("Bundle identifier does not match \(expectedBundleIdentifier).")
        }

        guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else {
            throw UpdateCheckerError.invalidAppBundle("Missing CFBundleExecutable.")
        }

        let executableURL = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UpdateCheckerError.invalidAppBundle("App executable is missing or not executable.")
        }
    }
}
