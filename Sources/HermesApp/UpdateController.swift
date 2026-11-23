import AppKit
import HermesKit

@MainActor
public final class UpdateController: NSObject, NSMenuItemValidation {
    public static let shared = UpdateController()

    private enum DefaultsKey {
        static let automaticChecks = "automaticallyChecksForUpdates"
        static let lastCheckDate = "lastUpdateCheckDate"
        static let skippedVersion = "skippedUpdateVersion"
    }

    private let defaults: UserDefaults
    private var isChecking = false
    private var activeDownloader: UpdateDownloader?
    private var pendingInstall: PendingInstall?

    private struct PendingInstall {
        let extractedAppURL: URL
        let destinationAppURL: URL
        let stagingDirectory: URL
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    public var repository: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "HermesGitHubRepo") as? String,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured
        }
        return UpdateChecker.defaultRepository
    }

    public var currentVersion: SemanticVersion {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let parsed = SemanticVersion(raw) {
            return parsed
        }
        return SemanticVersion(major: 0, minor: 1, patch: 0)
    }

    public var expectedBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "dev.hermes.hermes"
    }

    public var automaticallyChecksForUpdates: Bool {
        get {
            if defaults.object(forKey: DefaultsKey.automaticChecks) == nil {
                return true
            }
            return defaults.bool(forKey: DefaultsKey.automaticChecks)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.automaticChecks)
        }
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: DefaultsKey.skippedVersion) }
        set { defaults.set(newValue, forKey: DefaultsKey.skippedVersion) }
    }

    var lastCheckDate: Date? {
        get { defaults.object(forKey: DefaultsKey.lastCheckDate) as? Date }
        set { defaults.set(newValue, forKey: DefaultsKey.lastCheckDate) }
    }

    public func scheduleAutomaticCheckIfNeeded() {
        guard automaticallyChecksForUpdates else { return }
        guard ProcessInfo.processInfo.environment["HERMES_DISABLE_UPDATE_CHECK"] != "1" else { return }
        guard expectedBundleIdentifier != "dev.hermes.test-harness" else { return }
        guard UpdateChecker.shouldPerformAutomaticCheck(lastCheckDate: lastCheckDate) else { return }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.performCheck(userInitiated: false)
        }
    }

    @objc public func checkForUpdates(_ sender: Any?) {
        performCheck(userInitiated: true)
    }

    @objc public func toggleAutomaticUpdateChecks(_ sender: Any?) {
        automaticallyChecksForUpdates.toggle()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticUpdateChecks(_:)) {
            menuItem.state = automaticallyChecksForUpdates ? .on : .off
            return true
        }
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return !isChecking && activeDownloader == nil
        }
        return true
    }

    public func performCheck(userInitiated: Bool) {
        guard !isChecking, activeDownloader == nil else {
            if userInitiated {
                activeDownloader?.bringToFront()
            }
            return
        }

        isChecking = true
        let repo = repository
        let version = currentVersion
        let skipped = skippedVersion

        Task { [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }

            do {
                let outcome = try await UpdateChecker.fetchLatestRelease(
                    repository: repo,
                    currentVersion: version,
                    skippedVersion: skipped,
                    includeSkipped: userInitiated
                )
                self.lastCheckDate = Date()

                switch outcome {
                case .updateAvailable(let release):
                    self.presentUpdateAvailable(release)
                case .upToDate(let current, _):
                    if userInitiated {
                        self.presentUpToDate(currentVersion: current)
                    }
                }
            } catch {
                if userInitiated {
                    self.presentCheckError(error)
                }
            }
        }
    }

    // MARK: - Alerts

    func presentUpdateAvailable(_ release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "A new version of hermes is available."
        alert.informativeText = "hermes \(release.version) is now available — you have \(currentVersion). Would you like to download it now?"
        if let icon = NSApp.applicationIconImage {
            alert.icon = icon
        }

        if !release.notes.isEmpty {
            alert.accessoryView = makeReleaseNotesView(notes: release.notes)
        }

        if let asset = release.preferredDownloadAsset {
            let sizeSuffix = asset.size > 0
                ? " (\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)))"
                : ""
            alert.addButton(withTitle: "Download Update\(sizeSuffix)")
            alert.addButton(withTitle: "Remind Me Later")
            alert.addButton(withTitle: "Skip This Version")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                startDownload(asset: asset, release: release)
            case .alertThirdButtonReturn:
                skippedVersion = release.tagName
            default:
                break
            }
        } else {
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Remind Me Later")
            alert.addButton(withTitle: "Skip This Version")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(release.htmlURL)
            case .alertThirdButtonReturn:
                skippedVersion = release.tagName
            default:
                break
            }
        }
    }

    private func presentUpToDate(currentVersion: SemanticVersion) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You’re up to date."
        alert.informativeText = "hermes \(currentVersion) is currently the newest version available."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentCheckError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(UpdateChecker.releasesPageURL(forRepository: repository))
        }
    }

    private func makeReleaseNotesView(notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 364, height: 120))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textView.textColor = .labelColor
        textView.string = notes
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        return scroll
    }

    // MARK: - Download & Install

    private func startDownload(asset: ReleaseAsset, release: ReleaseInfo) {
        let downloader = UpdateDownloader(asset: asset, release: release) { [weak self] result in
            guard let self else { return }
            self.activeDownloader = nil
            switch result {
            case .cancelled:
                break
            case .failed(let message):
                self.presentDownloadError(message: message, release: release)
            case .downloaded(let fileURL, let stagingDirectory):
                self.handleDownloadedAsset(
                    fileURL: fileURL,
                    stagingDirectory: stagingDirectory,
                    asset: asset,
                    release: release
                )
            }
        }
        activeDownloader = downloader
        downloader.start()
    }

    private func presentDownloadError(message: String, release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update Download Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func handleDownloadedAsset(
        fileURL: URL,
        stagingDirectory: URL,
        asset: ReleaseAsset,
        release: ReleaseInfo
    ) {
        switch asset.kind {
        case .zip:
            extractAndOfferInstall(zipURL: fileURL, stagingDirectory: stagingDirectory, asset: asset, release: release)
        case .dmg, .pkg, .other:
            moveToDownloadsAndOfferOpen(fileURL: fileURL, stagingDirectory: stagingDirectory, asset: asset, release: release)
        }
    }

    private func extractAndOfferInstall(
        zipURL: URL,
        stagingDirectory: URL,
        asset: ReleaseAsset,
        release: ReleaseInfo
    ) {
        let extractDir = stagingDirectory.appendingPathComponent("extracted", isDirectory: true)
        let expectedBundleID = expectedBundleIdentifier

        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error> = Self.extractAndVerifyApp(
                zipURL: zipURL,
                extractDir: extractDir,
                expectedBundleIdentifier: expectedBundleID
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    try? FileManager.default.removeItem(at: stagingDirectory)
                    self.presentDownloadError(message: error.localizedDescription, release: release)
                case .success(let appURL):
                    self.presentReadyToInstall(
                        extractedAppURL: appURL,
                        zipURL: zipURL,
                        stagingDirectory: stagingDirectory,
                        asset: asset,
                        release: release
                    )
                }
            }
        }
    }

    private nonisolated static func extractAndVerifyApp(
        zipURL: URL,
        extractDir: URL,
        expectedBundleIdentifier: String
    ) -> Result<URL, Error> {
        do {
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-xk", zipURL.path, extractDir.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                return .failure(UpdateCheckerError.invalidAppBundle("Failed to unpack update archive."))
            }

            guard let appURL = findAppBundle(in: extractDir) else {
                return .failure(UpdateCheckerError.invalidAppBundle("No macOS application found inside the archive."))
            }

            try UpdateChecker.validateExtractedAppBundle(at: appURL, expectedBundleIdentifier: expectedBundleIdentifier)

            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--verify", "--deep", "--strict", appURL.path]
            codesign.standardOutput = FileHandle.nullDevice
            codesign.standardError = FileHandle.nullDevice
            try codesign.run()
            codesign.waitUntilExit()
            guard codesign.terminationStatus == 0 else {
                return .failure(UpdateCheckerError.invalidAppBundle("Code signature verification failed."))
            }

            return .success(appURL)
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func findAppBundle(in directory: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        if let direct = entries.first(where: { $0.pathExtension == "app" }) {
            return direct
        }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir, let nested = findAppBundle(in: entry) {
                return nested
            }
        }
        return nil
    }

    private func replaceableBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { return nil }
        return bundleURL
    }

    private func presentReadyToInstall(
        extractedAppURL: URL,
        zipURL: URL,
        stagingDirectory: URL,
        asset: ReleaseAsset,
        release: ReleaseInfo
    ) {
        NSApp.activate(ignoringOtherApps: true)
        if let destinationURL = replaceableBundleURL() {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "hermes \(release.version) is ready to install."
            alert.informativeText = "hermes will quit, replace the current app with version \(release.version), and relaunch automatically."
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "Cancel")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                pendingInstall = PendingInstall(
                    extractedAppURL: extractedAppURL,
                    destinationAppURL: destinationURL,
                    stagingDirectory: stagingDirectory
                )
                NSDocumentController.shared.closeAllDocuments(
                    withDelegate: self,
                    didCloseAllSelector: #selector(documentController(_:didCloseAll:contextInfo:)),
                    contextInfo: nil
                )
            case .alertSecondButtonReturn:
                if let saved = copyToDownloads(fileURL: zipURL, preferredName: asset.name) {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                }
                try? FileManager.default.removeItem(at: stagingDirectory)
            default:
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        } else {
            moveToDownloadsAndOfferOpen(fileURL: zipURL, stagingDirectory: stagingDirectory, asset: asset, release: release)
        }
    }

    @objc private func documentController(
        _ documentController: NSDocumentController,
        didCloseAll: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let install = pendingInstall else { return }
        pendingInstall = nil

        guard didCloseAll else {
            try? FileManager.default.removeItem(at: install.stagingDirectory)
            return
        }

        do {
            try Self.launchSwapAndRelaunchHelper(
                pid: ProcessInfo.processInfo.processIdentifier,
                sourceAppURL: install.extractedAppURL,
                destinationAppURL: install.destinationAppURL,
                stagingDirectory: install.stagingDirectory
            )
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: install.stagingDirectory)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Install Update"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func launchSwapAndRelaunchHelper(
        pid: Int32,
        sourceAppURL: URL,
        destinationAppURL: URL,
        stagingDirectory: URL
    ) throws {
        let script = """
        PID="$1"
        SRC="$2"
        DST="$3"
        STAGING="$4"
        BACKUP="${DST}.previous.$$"

        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.2
        done

        if [ -d "$DST" ]; then
            mv "$DST" "$BACKUP" || exit 1
        fi
        if mv "$SRC" "$DST"; then
            rm -rf "$BACKUP"
            rm -rf "$STAGING"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST" >/dev/null 2>&1 || true
            open "$DST"
        else
            if [ -d "$BACKUP" ]; then
                mv "$BACKUP" "$DST"
            fi
            exit 1
        fi
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "hermes-updater", "\(pid)", sourceAppURL.path, destinationAppURL.path, stagingDirectory.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    private func moveToDownloadsAndOfferOpen(
        fileURL: URL,
        stagingDirectory: URL,
        asset: ReleaseAsset,
        release: ReleaseInfo
    ) {
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        guard let savedURL = copyToDownloads(fileURL: fileURL, preferredName: asset.name) else {
            presentDownloadError(message: "Could not save the downloaded file to your Downloads folder.", release: release)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "hermes \(release.version) Downloaded"
        alert.informativeText = "Saved “\(savedURL.lastPathComponent)” to your Downloads folder."
        alert.addButton(withTitle: asset.kind == .zip ? "Reveal in Finder" : "Open Installer")
        alert.addButton(withTitle: asset.kind == .zip ? "Done" : "Reveal in Finder")
        if asset.kind != .zip {
            alert.addButton(withTitle: "Later")
        }

        let response = alert.runModal()
        if asset.kind == .zip {
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([savedURL])
            }
        } else {
            switch response {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(savedURL)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.activateFileViewerSelecting([savedURL])
            default:
                break
            }
        }
    }

    private func copyToDownloads(fileURL: URL, preferredName: String) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let safeName = URL(fileURLWithPath: preferredName).lastPathComponent
        let baseName = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension

        var target = downloads.appendingPathComponent(safeName)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let candidate = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            target = downloads.appendingPathComponent(candidate)
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: fileURL, to: target)
            return target
        } catch {
            return nil
        }
    }
}

// MARK: - Download Progress Window & Session

@MainActor
private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, NSWindowDelegate {
    enum Result {
        case downloaded(fileURL: URL, stagingDirectory: URL)
        case cancelled
        case failed(String)
    }

    private let asset: ReleaseAsset
    private let release: ReleaseInfo
    private let completion: (Result) -> Void

    private let panel: NSPanel
    private let statusLabel: NSTextField
    private let progressBar: NSProgressIndicator
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var finished = false

    init(asset: ReleaseAsset, release: ReleaseInfo, completion: @escaping (Result) -> Void) {
        self.asset = asset
        self.release = release
        self.completion = completion

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Software Update"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.center()

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content

        let iconView = NSImageView(frame: NSRect(x: 20, y: 44, width: 56, height: 56))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "Downloading hermes \(release.version)…")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: 92, y: 88, width: 308, height: 18)
        content.addSubview(titleLabel)

        let bar = NSProgressIndicator(frame: NSRect(x: 92, y: 60, width: 308, height: 16))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        content.addSubview(bar)

        let status = NSTextField(labelWithString: "Connecting…")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 92, y: 38, width: 220, height: 16)
        content.addSubview(status)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 324, y: 14, width: 76, height: 28)
        content.addSubview(cancelButton)

        self.panel = panel
        self.statusLabel = status
        self.progressBar = bar

        super.init()

        panel.delegate = self
        cancelButton.target = self
        cancelButton.action = #selector(cancelDownload(_:))
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        downloadTask?.cancel()
        finish(.cancelled)
    }

    func start() {
        guard asset.downloadURL.scheme?.lowercased() == "https" else {
            finish(.failed("Refused to download update over an insecure connection."))
            return
        }

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("Hermes", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.downloadTask = task

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        task.resume()
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelDownload(_ sender: Any?) {
        downloadTask?.cancel()
        finish(.cancelled)
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        panel.orderOut(nil)
        completion(result)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.asset.size
            let writtenText = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
            if expected > 0 {
                self.progressBar.isIndeterminate = false
                self.progressBar.doubleValue = min(1.0, Double(totalBytesWritten) / Double(expected))
                let totalText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                self.statusLabel.stringValue = "\(writtenText) of \(totalText)"
            } else {
                self.progressBar.isIndeterminate = true
                self.statusLabel.stringValue = "\(writtenText) downloaded"
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move out of URLSession's ephemeral location before returning from this callback.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-update-\(UUID().uuidString)", isDirectory: true)
        let safeName = URL(fileURLWithPath: asset.name).lastPathComponent
        let stagedFile = staging.appendingPathComponent(safeName)

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: stagedFile)
        } catch {
            MainActor.assumeIsolated {
                self.finish(.failed("Could not save downloaded update: \(error.localizedDescription)"))
            }
            return
        }

        MainActor.assumeIsolated {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: staging)
                self.finish(.failed("Download server returned HTTP \(http.statusCode)."))
                return
            }
            self.finish(.downloaded(fileURL: stagedFile, stagingDirectory: staging))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                self.finish(.cancelled)
            } else {
                self.finish(.failed(error.localizedDescription))
            }
        }
    }
}
