//
//  CompactUpdater.swift
//  Stats
//

import Cocoa
import CryptoKit
import Darwin
import Kit
import Security

internal extension Notification.Name {
    static let compactUpdateStateChanged = Notification.Name("compactUpdateStateChanged")
}

internal struct CompactForkRelease: Equatable {
    let tag: String
    let targetSHA: String
    let assetURL: String
    let assetDigest: String
    let pageURL: String
    let publishedAt: Int
}

internal struct CompactUpdateSnapshot {
    let needsAttention: Bool
    let color: NSColor
    let message: String
    let details: String
}

internal final class CompactUpdateMonitor {
    static let shared = CompactUpdateMonitor()

    let subtleNotificationsOnly = true

    private let staleInterval: TimeInterval = 8 * 24 * 60 * 60
    private let lock = NSLock()
    private var timer: Timer?
    private var lastSuccessValue: Int
    private var lastErrorValue: String
    private var releaseValue: CompactForkRelease?

    private var currentTag: String? {
        Bundle.main.object(forInfoDictionaryKey: "CompactReleaseTag") as? String
    }

    private init() {
        self.lastSuccessValue = Store.shared.int(key: "compact_update_last_success", defaultValue: 0)
        self.lastErrorValue = Store.shared.string(key: "compact_update_last_error", defaultValue: "")

        let tag = Store.shared.string(key: "compact_update_latest_tag", defaultValue: "")
        let sha = Store.shared.string(key: "compact_update_latest_sha", defaultValue: "")
        let url = Store.shared.string(key: "compact_update_latest_asset", defaultValue: "")
        let digest = Store.shared.string(key: "compact_update_latest_digest", defaultValue: "")
        let page = Store.shared.string(key: "compact_update_latest_page", defaultValue: "")
        let publishedAt = Store.shared.int(key: "compact_update_latest_published", defaultValue: 0)
        if !tag.isEmpty, !sha.isEmpty, !url.isEmpty, !digest.isEmpty, !page.isEmpty,
           publishedAt > 0 {
            self.releaseValue = CompactForkRelease(
                tag: tag,
                targetSHA: sha,
                assetURL: url,
                assetDigest: digest,
                pageURL: page,
                publishedAt: publishedAt
            )
        }
    }

    var latestRelease: CompactForkRelease? {
        self.lock.withLock { self.releaseValue }
    }

    var needsAttention: Bool {
        self.snapshot.needsAttention
    }

    var snapshot: CompactUpdateSnapshot {
        self.lock.withLock {
            let release = self.releaseValue
            let lastSuccess = self.lastSuccessValue
            let lastError = self.lastErrorValue
            let now = Int(Date().timeIntervalSince1970)
            let age = lastSuccess == 0 ? Int.max : max(0, now - lastSuccess)
            let available = release.map { $0.tag != self.currentTag } ?? false
            let stale = age >= Int(self.staleInterval)
            let releaseAge = release.map { max(0, now - $0.publishedAt) }
            let releaseIsStale = releaseAge.map { $0 >= Int(self.staleInterval) } ?? false

            if available, let release {
                return CompactUpdateSnapshot(
                    needsAttention: true,
                    color: .systemRed,
                    message: "Update available · \(release.tag)",
                    details: "The latest public release of tovam/stats-macos is ready."
                )
            }

            if lastSuccess == 0 {
                return CompactUpdateSnapshot(
                    needsAttention: true,
                    color: .systemRed,
                    message: "Update status has not been checked yet",
                    details: lastError.isEmpty ? "Waiting for the first successful check." : lastError
                )
            }

            if stale {
                return CompactUpdateSnapshot(
                    needsAttention: true,
                    color: .systemRed,
                    message: "Update check overdue · \(self.relativeAge(age))",
                    details: lastError.isEmpty
                        ? "No successful fork update check for more than eight days."
                        : lastError
                )
            }

            if releaseIsStale, let releaseAge {
                return CompactUpdateSnapshot(
                    needsAttention: true,
                    color: .systemRed,
                    message: "Latest fork release · \(self.relativeAge(releaseAge))",
                    details: "The weekly tovam/stats-macos release may need attention."
                )
            }

            if !lastError.isEmpty {
                return CompactUpdateSnapshot(
                    needsAttention: false,
                    color: .systemOrange,
                    message: "Latest check failed · last success \(self.relativeAge(age))",
                    details: lastError
                )
            }

            return CompactUpdateSnapshot(
                needsAttention: false,
                color: .systemGreen,
                message: "Fork is up to date · checked \(self.relativeAge(age))",
                details: release?.tag ?? "No published release metadata cached."
            )
        }
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
                self?.notify()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            self.notify()
        }
    }

    func recordSuccess(_ release: CompactForkRelease) {
        let now = Int(Date().timeIntervalSince1970)
        self.lock.withLock {
            self.lastSuccessValue = now
            self.lastErrorValue = ""
            self.releaseValue = release
        }

        Store.shared.set(key: "compact_update_last_success", value: now)
        Store.shared.set(key: "compact_update_last_error", value: "")
        Store.shared.set(key: "compact_update_latest_tag", value: release.tag)
        Store.shared.set(key: "compact_update_latest_sha", value: release.targetSHA)
        Store.shared.set(key: "compact_update_latest_asset", value: release.assetURL)
        Store.shared.set(key: "compact_update_latest_digest", value: release.assetDigest)
        Store.shared.set(key: "compact_update_latest_page", value: release.pageURL)
        Store.shared.set(key: "compact_update_latest_published", value: release.publishedAt)
        self.notify()
    }

    func recordFailure(_ message: String) {
        self.lock.withLock {
            self.lastErrorValue = message
        }
        Store.shared.set(key: "compact_update_last_error", value: message)
        self.notify()
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .compactUpdateStateChanged, object: nil)
        }
    }

    private func relativeAge(_ seconds: Int) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 60 * 60 { return "\(seconds / 60) min ago" }
        if seconds < 24 * 60 * 60 { return "\(seconds / (60 * 60)) h ago" }
        return "\(seconds / (24 * 60 * 60)) d ago"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}

internal final class CompactUpdateStatusView: NSStackView {
    private let dot = CompactUpdateDotView()
    private let field = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        self.orientation = .horizontal
        self.alignment = .centerY
        self.spacing = 6
        self.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        self.dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        self.dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        self.field.font = NSFont.systemFont(ofSize: 10)
        self.field.textColor = .secondaryLabelColor
        self.field.lineBreakMode = .byTruncatingMiddle
        self.field.maximumNumberOfLines = 1

        self.addArrangedSubview(self.dot)
        self.addArrangedSubview(self.field)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.updateState),
            name: .compactUpdateStateChanged,
            object: nil
        )
        self.updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func updateState() {
        let state = CompactUpdateMonitor.shared.snapshot
        self.dot.color = state.color
        self.field.stringValue = state.message
        self.toolTip = state.details
    }
}

private final class CompactUpdateDotView: NSView {
    var color: NSColor = .secondaryLabelColor {
        didSet { self.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        self.color.setFill()
        NSBezierPath(ovalIn: self.bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

internal final class CompactUpdater {
    let usesSubtleIndicator = true

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case digest
            }
        }

        let tagName: String
        let targetCommitish: String
        let htmlURL: String
        let publishedAt: Date
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case targetCommitish = "target_commitish"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    private let endpoint = URL(string: "https://api.github.com/repos/tovam/stats-macos/releases/latest")!
    private let expectedLock = NSLock()
    private var expectedByURL: [String: CompactForkRelease] = [:]
    private var expectedByPath: [String: CompactForkRelease] = [:]
    private var observation: NSKeyValueObservation?

    private var currentTag: String? {
        Bundle.main.object(forInfoDictionaryKey: "CompactReleaseTag") as? String
    }
    private var currentDisplayVersion: String {
        if let currentTag { return currentTag }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "v\(version) · unstamped fork build"
    }
    private var lastCheckTS: Int {
        get { Store.shared.int(key: "compact_updater_check_ts", defaultValue: -1) }
        set { Store.shared.set(key: "compact_updater_check_ts", value: newValue) }
    }
    private var lastInstallTS: Int {
        get { Store.shared.int(key: "compact_updater_install_ts", defaultValue: -1) }
        set { Store.shared.set(key: "compact_updater_install_ts", value: newValue) }
    }

    init() {
        CompactUpdateMonitor.shared.start()
    }

    deinit {
        self.observation?.invalidate()
    }

    func check(force: Bool = false, completion: @escaping (version_s?, Error?) -> Void) {
        let now = Int(Date().timeIntervalSince1970)
        let minutes = (now - self.lastCheckTS) / 60
        if !force && minutes <= 10 {
            if let release = CompactUpdateMonitor.shared.latestRelease {
                completion(self.version(from: release), nil)
            } else {
                completion(nil, self.error("A fork update check ran less than ten minutes ago."))
            }
            return
        }
        self.lastCheckTS = now

        var request = URLRequest(url: self.endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Stats-Compact-Updater", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.fail(error.localizedDescription, completion: completion)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                self.fail("GitHub returned an invalid response.", completion: completion)
                return
            }

            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let payload = try decoder.decode(GitHubRelease.self, from: data)
                guard let asset = payload.assets.first(where: { $0.name == "Stats-Compact.app.zip" }),
                      let digest = asset.digest,
                      digest.hasPrefix("sha256:"),
                      self.isAllowedDownloadURL(asset.browserDownloadURL) else {
                    self.fail("The latest release does not contain a valid Stats-Compact.app.zip asset.", completion: completion)
                    return
                }

                let release = CompactForkRelease(
                    tag: payload.tagName,
                    targetSHA: payload.targetCommitish,
                    assetURL: asset.browserDownloadURL,
                    assetDigest: digest,
                    pageURL: payload.htmlURL,
                    publishedAt: Int(payload.publishedAt.timeIntervalSince1970)
                )
                self.expectedLock.withLock {
                    self.expectedByURL[release.assetURL] = release
                }
                CompactUpdateMonitor.shared.recordSuccess(release)
                completion(self.version(from: release), nil)
            } catch {
                self.fail("Could not parse the fork release: \(error.localizedDescription)", completion: completion)
            }
        }.resume()
    }

    func download(
        _ url: URL,
        progress: @escaping (Progress) -> Void = { _ in },
        completion: @escaping (String) -> Void = { _ in }
    ) {
        guard url.scheme == "https",
              let release = self.expectedLock.withLock({ self.expectedByURL[url.absoluteString] })
                ?? CompactUpdateMonitor.shared.latestRelease,
              release.assetURL == url.absoluteString else {
            self.showError("Rejected an unexpected update download URL.")
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, _, error in
            guard let self else { return }
            if let error {
                self.showError("Update download failed: \(error.localizedDescription)")
                return
            }
            guard let temporaryURL else {
                self.showError("Update download did not return a file.")
                return
            }

            do {
                let digest = try self.sha256(of: temporaryURL)
                guard release.assetDigest == "sha256:\(digest)" else {
                    self.showError("Update archive checksum mismatch.")
                    return
                }

                let downloads = try FileManager.default.url(
                    for: .downloadsDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
                let safeTag = release.tag.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                var destination = downloads.appendingPathComponent("Stats-Compact-\(safeTag).app.zip")
                if FileManager.default.fileExists(atPath: destination.path) {
                    destination = downloads.appendingPathComponent(
                        "Stats-Compact-\(safeTag)-\(UUID().uuidString).app.zip"
                    )
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                self.expectedLock.withLock {
                    self.expectedByPath[destination.standardizedFileURL.path] = release
                }
                completion(destination.path)
            } catch {
                self.showError("Could not stage the update: \(error.localizedDescription)")
            }
        }

        self.observation = task.progress.observe(\.fractionCompleted) { value, _ in
            progress(value)
        }
        task.resume()
    }

    func install(path: String, completion: @escaping (String?) -> Void) {
        let archive = URL(fileURLWithPath: path.replacingOccurrences(of: "file://", with: ""))
            .standardizedFileURL
        let fileManager = FileManager.default

        do {
            let downloads = try fileManager.url(
                for: .downloadsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).standardizedFileURL
            guard archive.path.hasPrefix(downloads.path + "/"),
                  archive.pathExtension == "zip",
                  !archive.path.contains(".."),
                  fileManager.fileExists(atPath: archive.path) else {
                completion("Rejected an update archive outside Downloads.")
                return
            }

            guard let release = self.expectedLock.withLock({ self.expectedByPath[archive.path] })
                    ?? CompactUpdateMonitor.shared.latestRelease else {
                completion("Missing release metadata for this archive.")
                return
            }
            guard release.assetDigest == "sha256:\(try self.sha256(of: archive))" else {
                completion("Update archive checksum mismatch.")
                return
            }

            let minutes = (Int(Date().timeIntervalSince1970) - self.lastInstallTS) / 60
            guard minutes > 3 else {
                completion("An update installation already ran \(minutes) minutes ago.")
                return
            }

            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("StatsCompact-update-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)

            let extraction = self.runProcess("/usr/bin/ditto", ["-x", "-k", archive.path, root.path])
            guard extraction.exit == 0 else {
                try? fileManager.removeItem(at: root)
                completion("Could not extract the update: \(extraction.error)")
                return
            }

            let candidate = root.appendingPathComponent("Stats Compact.app", isDirectory: true)
            guard try self.validate(candidate: candidate, release: release) else {
                try? fileManager.removeItem(at: root)
                completion("The extracted app failed validation.")
                return
            }

            let currentApp = Bundle.main.bundleURL.standardizedFileURL
            guard currentApp.lastPathComponent == "Stats Compact.app",
                  Bundle.main.bundleIdentifier == "com.tovam.StatsCompact",
                  !currentApp.path.contains("..") else {
                try? fileManager.removeItem(at: root)
                completion("The current application path is not safe to replace.")
                return
            }

            let scriptSource = candidate
                .appendingPathComponent("Contents/Resources/Scripts/updater.sh")
            let script = root.appendingPathComponent("compact-updater.sh")
            try fileManager.copyItem(at: scriptSource, to: script)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

            let parent = currentApp.deletingLastPathComponent()
            let args = [
                script.path,
                "--app", parent.path,
                "--dmg", archive.path,
                "--mount", root.path,
                "--user", String(getuid())
            ]

            if !fileManager.isWritableFile(atPath: parent.path) {
                if let error = self.runElevated("/bin/bash", args: args) {
                    try? fileManager.removeItem(at: root)
                    completion("Elevated update failed: \(error)")
                    return
                }
            } else {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = args
                try task.run()
            }

            self.lastInstallTS = Int(Date().timeIntervalSince1970)
            exit(0)
        } catch {
            completion("Update installation failed: \(error.localizedDescription)")
        }
    }

    private func version(from release: CompactForkRelease) -> version_s {
        version_s(
            current: self.currentDisplayVersion,
            latest: release.tag,
            newest: self.currentTag != release.tag,
            url: release.assetURL
        )
    }

    private func fail(
        _ message: String,
        completion: @escaping (version_s?, Error?) -> Void
    ) {
        CompactUpdateMonitor.shared.recordFailure(message)
        completion(nil, self.error(message))
    }

    private func error(_ message: String) -> Error {
        NSError(
            domain: "CompactUpdater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func showError(_ message: String) {
        CompactUpdateMonitor.shared.recordFailure(message)
        DispatchQueue.main.async {
            showAlert("Stats Compact update", message, .critical)
        }
    }

    private func isAllowedDownloadURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
            return false
        }
        return url.path.hasPrefix("/tovam/stats-macos/releases/download/") &&
            url.lastPathComponent == "Stats-Compact.app.zip"
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(candidate: URL, release: CompactForkRelease) throws -> Bool {
        let values = try candidate.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              candidate.standardizedFileURL.path.hasPrefix(
                candidate.deletingLastPathComponent().standardizedFileURL.path + "/"
              ),
              let bundle = Bundle(url: candidate),
              bundle.bundleIdentifier == "com.tovam.StatsCompact",
              bundle.object(forInfoDictionaryKey: "CompactReleaseRepository") as? String == "tovam/stats-macos",
              bundle.object(forInfoDictionaryKey: "CompactReleaseTag") as? String == release.tag,
              bundle.object(forInfoDictionaryKey: "CompactBuildSHA") as? String == release.targetSHA,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return false
        }
        return true
    }

    private func runProcess(_ executable: String, _ arguments: [String]) -> (
        output: String,
        error: String,
        exit: Int32
    ) {
        let task = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ("", error.localizedDescription, -1)
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (output, error, task.terminationStatus)
    }

    private func runElevated(_ tool: String, args: [String]) -> String? {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            return "AuthorizationCreate failed (\(createStatus))"
        }
        defer { AuthorizationFree(authorization, [.destroyRights]) }

        typealias ExecuteWithPrivileges = @convention(c) (
            AuthorizationRef,
            UnsafePointer<CChar>,
            AuthorizationFlags,
            UnsafePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
        ) -> OSStatus
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "AuthorizationExecuteWithPrivileges"
        ) else {
            return "AuthorizationExecuteWithPrivileges unavailable"
        }
        let execute = unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)

        var cArguments: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArguments.append(nil)
        defer { cArguments.forEach { free($0) } }

        let result: OSStatus = tool.withCString { pointer in
            cArguments.withUnsafeMutableBufferPointer { buffer in
                execute(authorization, pointer, [], buffer.baseAddress!, nil)
            }
        }
        if result == errAuthorizationCanceled { return "user canceled" }
        if result != errAuthorizationSuccess {
            return "AuthorizationExecuteWithPrivileges failed (\(result))"
        }
        return nil
    }
}
