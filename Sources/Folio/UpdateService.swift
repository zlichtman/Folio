import AppKit
import Combine
import ShelfCore
@preconcurrency import UserNotifications

// Ported from MacSpaces' Services/UpdateService.swift (same author, MIT).

/// Reads Folio's latest GitHub release, downloads and verifies Folio.dmg, and replaces the
/// app in /Applications only after the user agrees.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()
    static let bundleIdentifier = "org.lumashelf.app"
    nonisolated static let teamIdentifier = "28LJG7MXT3"
    static let releasesPage = URL(string:"https://github.com/zlichtman/Folio/releases")!
    private static let endpoint = URL(string:"https://api.github.com/repos/zlichtman/Folio/releases/latest")!

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(String)
        case downloading(String)
        case installing(String)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Check for Updates"
            case .checking: return "Checking…"
            case .upToDate: return "Folio is up to date"
            case .available(let version): return "Folio \(version) is available"
            case .downloading(let version): return "Downloading \(version)…"
            case .installing(let version): return "Installing \(version)…"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?
    /// The release page of the update on offer, for "What's new".
    @Published private(set) var releasePage: URL?
    /// What the available update brings, from its release notes.
    @Published private(set) var releaseNotes: [(title: String, points: [String])] = []
    @Published var automaticallyCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyCheckForUpdates,forKey:Key.automaticCheck); if automaticallyCheckForUpdates { checkIfDue() } }
    }
    @Published var automaticallyInstallUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyInstallUpdates,forKey:Key.automatic) }
    }

    private enum Key {
        static let automatic = "updates.automaticallyInstall", automaticCheck = "updates.automaticallyCheck"
        static let lastCheck = "updates.lastCheck"
        /// A build this Mac can't run, so it isn't downloaded again on every check.
        static let incompatibleBuild = "updates.incompatibleBuild"
    }

    /// Bounded so a stalled connection can't leave the UI on "Checking…" forever.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 900
        return URLSession(configuration:configuration)
    }()
    private var busy = false
    private var available: (url: URL, version: String, build: Int)?
    private var periodicCheck: Timer?

    private init() {
        // Updates download on their own by default; Folio still asks before it relaunches.
        UserDefaults.standard.register(defaults:[Key.automatic:true,Key.automaticCheck:true])
        automaticallyInstallUpdates = UserDefaults.standard.bool(forKey:Key.automatic)
        automaticallyCheckForUpdates = UserDefaults.standard.bool(forKey:Key.automaticCheck)
        lastCheck = UserDefaults.standard.object(forKey:Key.lastCheck) as? Date
    }

    /// Development builds use another bundle identifier and never update.
    var isSupported: Bool { Bundle.main.bundleIdentifier == Self.bundleIdentifier }
    var actionLabel: String { if case .available = status { return "Install" }; return "Check Now" }
    var isBusy: Bool {
        switch status { case .checking, .downloading, .installing: return true; default: return false }
    }

    func start() {
        guard isSupported, periodicCheck == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for:.seconds(8))
            checkIfDue()
        }
        // Folio can stay open for days, so checking only at launch would miss releases.
        periodicCheck = Timer.scheduledTimer(withTimeInterval:60*60,repeats:true) { _ in
            Task { @MainActor in UpdateService.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard isSupported, automaticallyCheckForUpdates else { return }
        if case .available = status { return }
        guard lastCheck.map({ Date().timeIntervalSince($0) > 6*60*60 }) ?? true else { return }
        check(manual:false)
    }

    func performPrimaryAction() {
        if case .available = status, let available { downloadAndInstall(available.url,version:available.version,build:available.build) }
        else { check() }
    }

    func check(manual: Bool = true) {
        guard !busy else { return }
        guard isSupported else { status = .failed("Updates are off in development builds"); return }
        busy = true; status = .checking
        Task { @MainActor in
            let found = await findUpdate(manual:manual)
            busy = false
            if let found, automaticallyInstallUpdates { downloadAndInstall(found.url,version:found.version,build:found.build) }
        }
    }

    private func findUpdate(manual: Bool) async -> (url: URL, version: String, build: Int)? {
        var request = URLRequest(url:Self.endpoint)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue("Folio/\(currentVersion)",forHTTPHeaderField:"User-Agent")
        guard let (data,response) = try? await session.data(for:request) else {
            status = manual ? .failed("Couldn’t check for updates") : .idle; return nil
        }
        lastCheck = Date(); UserDefaults.standard.set(lastCheck,forKey:Key.lastCheck)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let latest = ReleaseRevision.latest(from:data) else {
            status = manual ? .failed(code == 403 || code == 429 ? "GitHub is busy. Try again in a few minutes." : "Couldn’t check for updates") : .idle
            return nil
        }
        let skipped = UserDefaults.standard.integer(forKey:Key.incompatibleBuild)
        guard ReleaseRevision.isNewer(latest.build,than:max(currentBuild,skipped)) else {
            available = nil; releasePage = nil; releaseNotes = []
            status = manual ? .upToDate : .idle
            return nil
        }
        guard let asset = ReleaseRevision.asset(in:latest.release) else { status = .failed("Update is missing Folio.dmg"); return nil }
        // The download location comes from a JSON payload, so it's pinned to HTTPS on
        // GitHub's own asset hosts rather than followed wherever it points.
        guard ReleaseRevision.isTrustedDownload(asset.url) else { status = .failed("Update came from an unexpected location"); return nil }
        releasePage = latest.release.page; releaseNotes = ReleaseRevision.sections(in:latest.release.body)
        // Copies that can't replace themselves say why instead of downloading for nothing.
        if let problem = await installProblem() { available = nil; status = .failed(problem); return nil }
        available = (asset.url,latest.version,latest.build)
        status = .available(latest.version)
        notifyAvailable(latest.version)
        return available
    }

    private func installProblem() async -> String? {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard ReleaseRevision.canReplaceApp(at:app.path) else { return "Move Folio to Applications, then install the update" }
        guard FileManager.default.isWritableFile(atPath:app.deletingLastPathComponent().path) else { return "Your account can’t update apps in Applications" }
        guard await Task.detached(operation:{ Self.signingTeam(at:app) }).value != nil else { return "This copy of Folio can’t install updates. Download the new version from GitHub." }
        return nil
    }

    private func downloadAndInstall(_ url: URL, version: String, build: Int) {
        guard !busy else { return }
        available = nil; busy = true
        status = .downloading(version)
        var request = URLRequest(url:url)
        request.setValue("Folio/\(currentVersion)",forHTTPHeaderField:"User-Agent")
        Task { @MainActor in
            do {
                let (temporary,response) = try await session.download(for:request,delegate:RedirectGuard())
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.commandFailed }
                let retained = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-\(UUID().uuidString).dmg")
                try FileManager.default.moveItem(at:temporary,to:retained)
                busy = false
                install(retained,version:version,build:build,source:url)
            } catch {
                busy = false
                status = .failed("Update download failed")
            }
        }
    }

    private func install(_ diskImage: URL, version: String, build: Int, source: URL) {
        status = .installing(version)
        let expectation = Expectation(bundleIdentifier:Self.bundleIdentifier,version:version,build:build,installed:Bundle.main.bundleURL)
        Task {
            // Mounting, verifying and copying takes seconds; keep the UI responsive.
            let result = await Task.detached(priority:.userInitiated) { Result { try Self.stageVerifiedApp(from:diskImage,expectation) } }.value
            guard case let .success(staged) = result else {
                if case let .failure(error) = result, case UpdateError.incompatible? = error as? UpdateError {
                    UserDefaults.standard.set(build,forKey:Key.incompatibleBuild)
                    status = .failed("Folio \(version) doesn’t support this Mac")
                } else {
                    status = .failed("Update verification failed")
                }
                return
            }
            guard confirmRelaunch(version:version) else {
                // Keep the offer so Install works again later.
                available = (source,version,build)
                status = .available(version)
                try? FileManager.default.removeItem(at:staged.root)
                return
            }
            do {
                try scheduleReplacement(with:staged)
                NSApp.terminate(nil)
            } catch UpdateError.notInstalled {
                status = .failed("Move Folio to Applications, then install the update")
                try? FileManager.default.removeItem(at:staged.root)
            } catch {
                status = .failed("Couldn’t install the update")
                try? FileManager.default.removeItem(at:staged.root)
            }
        }
    }

    /// Quitting and relaunching needs an explicit yes, even with automatic installs on.
    private func confirmRelaunch(version: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install Folio \(version)?"
        alert.informativeText = "Folio will quit and reopen to finish installing."
        alert.icon = FolioIcon.image
        alert.addButton(withTitle:"Install and Relaunch")
        alert.addButton(withTitle:"Later")
        NSApp.activate(ignoringOtherApps:true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private struct Expectation: Sendable {
        let bundleIdentifier: String
        let version: String
        let build: Int
        let installed: URL
    }
    private struct StagedUpdate: Sendable {
        let root: URL
        let app: URL
    }

    /// Mounts the image read-only and copies the app out only if it is the expected release,
    /// runs on this Mac, and is signed by Folio's developer team, the same as this copy.
    nonisolated private static func stageVerifiedApp(from diskImage: URL, _ expected: Expectation) throws -> StagedUpdate {
        let fm = FileManager.default
        let id = UUID().uuidString
        let root = fm.temporaryDirectory.appendingPathComponent("FolioUpdate-\(id)",isDirectory:true)
        let mount = fm.temporaryDirectory.appendingPathComponent("FolioMount-\(id)",isDirectory:true)
        let staged = root.appendingPathComponent("Folio.app",isDirectory:true)
        defer { try? fm.removeItem(at:diskImage) }
        do {
            try fm.createDirectory(at:mount,withIntermediateDirectories:true)
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            try run("/usr/bin/hdiutil",["attach","-nobrowse","-readonly","-noautoopen","-mountpoint",mount.path,diskImage.path])
        } catch {
            try? fm.removeItem(at:mount); try? fm.removeItem(at:root); throw error
        }
        let result = Result { try verifyAndCopy(mount.appendingPathComponent("Folio.app",isDirectory:true),to:staged,expected) }
        if (try? run("/usr/bin/hdiutil",["detach",mount.path])) == nil { _ = try? run("/usr/bin/hdiutil",["detach","-force",mount.path]) }
        try? fm.removeItem(at:mount)
        if case .failure = result { try? fm.removeItem(at:root) }
        return StagedUpdate(root:root,app:try result.get())
    }

    nonisolated private static func verifyAndCopy(_ mountedApp: URL, to staged: URL, _ expected: Expectation) throws -> URL {
        guard let info = Bundle(url:mountedApp), info.bundleIdentifier == expected.bundleIdentifier,
              ReleaseRevision.compare(info.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "",expected.version) == .orderedSame,
              Int(info.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "") == expected.build else {
            throw UpdateError.invalidBundle
        }
        guard canRun(info) else { throw UpdateError.incompatible }
        try run("/usr/bin/codesign",["--verify","--deep","--strict",mountedApp.path])
        // Unsigned and ad-hoc copies have no team, so they never match.
        guard let team = signingTeam(at:mountedApp), team == teamIdentifier, team == signingTeam(at:expected.installed) else {
            throw UpdateError.invalidSignature
        }
        try run("/usr/bin/ditto",[mountedApp.path,staged.path])
        // Folio quarantines files it writes (LSFileQuarantineEnabled). A quarantined app would
        // be translocated on relaunch, so the verified copy is cleared before it moves in.
        try removeQuarantine(staged)
        try run("/usr/bin/codesign",["--verify","--deep","--strict",staged.path])
        return staged
    }

    nonisolated private static func removeQuarantine(_ app: URL) throws {
        let name = "com.apple.quarantine"
        var paths = [app.path]
        if let files = FileManager.default.enumerator(atPath:app.path) { while let file = files.nextObject() as? String { paths.append(app.appendingPathComponent(file).path) } }
        for path in paths where removexattr(path,name,XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw UpdateError.commandFailed }
    }

    /// Runs after Folio quits: copies beside the app, swaps it in, rolls back on failure, reopens Folio.
    private func scheduleReplacement(with staged: StagedUpdate) throws {
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard ReleaseRevision.canReplaceApp(at:destination.path) else { throw UpdateError.notInstalled }
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        destination=\(shellQuote(destination.path))
        staged=\(shellQuote(staged.app.path))
        staging_root=\(shellQuote(staged.root.path))
        incoming="${destination}.incoming"
        backup="${destination}.previous"
        /bin/rm -rf "$incoming" "$backup"
        /usr/bin/ditto "$staged" "$incoming" || { /bin/rm -rf "$incoming" "$staging_root"; /usr/bin/open "$destination"; exit 1; }
        /bin/mv "$destination" "$backup" || { /bin/rm -rf "$incoming" "$staging_root"; /usr/bin/open "$destination"; exit 1; }
        /bin/mv "$incoming" "$destination" || { /bin/mv "$backup" "$destination"; /bin/rm -rf "$incoming" "$staging_root"; /usr/bin/open "$destination"; exit 1; }
        /bin/rm -rf "$backup" "$staging_root"
        /usr/bin/open "$destination"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath:"/bin/sh"); process.arguments = ["-c",script]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Whether this Mac can run the downloaded app: its minimum macOS and an executable
    /// slice for this process's architecture.
    nonisolated private static func canRun(_ app: Bundle) -> Bool {
        if let minimum = app.object(forInfoDictionaryKey:"LSMinimumSystemVersion") as? String {
            let parts = minimum.split(separator:".").map { Int($0) ?? 0 }
            let required = OperatingSystemVersion(majorVersion:parts.first ?? 0,minorVersion:parts.count > 1 ? parts[1] : 0,patchVersion:parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else { return false }
        }
        #if arch(x86_64)
        let architecture = NSBundleExecutableArchitectureX86_64
        #else
        let architecture = NSBundleExecutableArchitectureARM64
        #endif
        return app.executableArchitectures?.contains(NSNumber(value:architecture)) == true
    }

    /// Nil for unsigned and ad-hoc signatures, which report "TeamIdentifier=not set" and
    /// would otherwise match each other.
    nonisolated private static func signingTeam(at app: URL) -> String? {
        guard let output = try? run("/usr/bin/codesign",["-dv","--verbose=4",app.path]) else { return nil }
        let team = output.split(separator:"\n").first { $0.hasPrefix("TeamIdentifier=") }?
            .split(separator:"=",maxSplits:1).last.map { $0.trimmingCharacters(in:.whitespaces) }
        guard let team, !team.isEmpty, team != "not set" else { return nil }
        return team
    }

    @discardableResult
    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let pipe = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed }
        return String(decoding:data,as:UTF8.self)
    }

    private func shellQuote(_ value: String) -> String { "'\(value.replacingOccurrences(of:"'",with:"'\\''"))'" }
    private var currentVersion: String { AppIdentity.version }
    private var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "") ?? 0 }

    private func notifyAvailable(_ version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Folio \(version)"
        content.body = automaticallyInstallUpdates
            ? "Downloading the update. You’ll be asked before it installs."
            : "Open Settings ▸ Updates to install the update."
        let request = UNNotificationRequest(identifier:"folio-update-\(version)",content:content,trigger:nil)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: center.add(request)
            case .notDetermined: center.requestAuthorization(options:[.alert]) { granted, _ in if granted { center.add(request) } }
            default: break
            }
        }
    }

    private enum UpdateError: Error {
        case invalidBundle, invalidSignature, incompatible, notInstalled, commandFailed
    }
}

/// Follows download redirects only to GitHub's asset hosts.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        request.url.map(ReleaseRevision.isTrustedDownload) == true ? request : nil
    }
}
