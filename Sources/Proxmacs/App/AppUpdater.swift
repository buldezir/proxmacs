import AppKit
import Observation
import Sparkle

/// The app's updates, through Sparkle: it reads the latest release's feed
/// (SUFeedURL, which scripts/appcast.sh writes) once a day, shows the new
/// version's notes and installs it. An update that a daily check finds while
/// the app is in the background doesn't put a window in front of the user's
/// work: it waits in the menu, where choosing it opens Sparkle's dialog. The
/// web UI can check and install too, without Sparkle's windows, since whoever
/// uses it is rarely at the Mac (`UpdateDriver`). Only release builds update;
/// a local build is version 0.1.
@MainActor @Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// The step an install started from the web UI is at.
    enum Phase: String { case checking, downloading, extracting, installing }

    struct Release {
        var version: String
        var date: Date?
        /// Markdown: the release's notes, up to its downloads.
        var notes: String?
        var url: URL?
    }

    let version: String
    let isRelease: Bool
    /// The version a daily check found, until the user looks at it.
    private(set) var available: String?
    /// False while a check or an update is under way.
    private(set) var canCheck = false
    /// The newest release the last check found, if it is newer than this one.
    fileprivate(set) var found: Release?
    /// True during a check started from the web UI.
    private(set) var checking = false
    /// An install the web UI started; nil when there is none.
    fileprivate(set) var phase: Phase?
    /// 0...1 while downloading or extracting, when Sparkle knows.
    fileprivate(set) var progress: Double?
    /// Why the last check or install from the web UI failed.
    fileprivate(set) var lastError: String?

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var driver: UpdateDriver?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private override init() {
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        isRelease = Self.isRelease(version)
        super.init()
    }

    /// Starts the daily checks, once, when the app launches.
    func start() {
        guard isRelease, updater == nil else { return }
        let driver = UpdateDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: self))
        driver.owner = self
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            lastError = "Proxmacs can't check for updates: \(error.localizedDescription)"
            return
        }
        self.driver = driver
        self.updater = updater
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    /// Why the web UI can't update this copy of Proxmacs, if it can't.
    var unsupportedReason: String? {
        if !isRelease { return "A local build of Proxmacs doesn't update itself" }
        if updater == nil { return lastError ?? "Proxmacs updates itself only while its menubar app runs" }
        return nil
    }

    var lastChecked: Date? { updater?.lastUpdateCheckDate }

    func checkForUpdates() {
        guard phase == nil else { return }
        NSApp.activate()
        updater?.checkForUpdates()
    }

    /// Checks the feed without offering the update, for the web UI, which
    /// shows `found` once `checking` is false again.
    func checkInBackground() throws {
        guard let updater else { throw ProxmacsError(unsupportedReason ?? "") }
        // An update being offered or installed is already known.
        guard !updater.sessionInProgress else { return }
        lastError = nil
        checking = true
        updater.checkForUpdateInformation()
    }

    /// Installs the newest release, for the web UI, without asking on the
    /// Mac. Proxmacs quits and opens again; VMs keep running.
    func install() throws {
        guard let updater, let driver else { throw ProxmacsError(unsupportedReason ?? "") }
        guard phase == nil else { return }
        lastError = nil
        // The update a daily check offers, in the menu or in Sparkle's window.
        if driver.takeOver() {
            phase = .downloading
            return
        }
        guard !updater.sessionInProgress else {
            throw ProxmacsError("Proxmacs is already checking for or installing an update; try again in a minute")
        }
        phase = .checking
        progress = nil
        updater.checkForUpdates()
    }

    fileprivate func fail(_ message: String) {
        lastError = message
        phase = nil
        progress = nil
    }

    /// The menu item that offers the update a daily check found, or a check.
    var menuTitle: String {
        if phase != nil { return "Updating…" }
        return available.map { "Update to \($0)…" } ?? "Check for Updates…"
    }

    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) { updater?.automaticallyChecksForUpdates = newValue }
        }
    }

    var downloadsAutomatically: Bool {
        get {
            access(keyPath: \.downloadsAutomatically)
            return updater?.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.downloadsAutomatically) { updater?.automaticallyDownloadsUpdates = newValue }
        }
    }

    /// A release's version is X.Y.Z or X.Y.Z-pre. A local build's, such as
    /// "0.1" or git describe's "0.1.2-6-gd609b51", isn't.
    nonisolated static func isRelease(_ version: String) -> Bool {
        version.wholeMatch(of: #/\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?/#) != nil && !version.contains(#/-\d+-g[0-9a-f]+$/#)
    }
}

extension AppUpdater: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found = Release(version: item.displayVersionString, date: item.date, notes: item.itemDescription,
                        url: item.fullReleaseNotesURL ?? item.infoURL)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        found = nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if updateCheck == .updateInformation { checking = false }
        guard let error = error as NSError?, error.domain == SUSparkleErrorDomain,
              error.code != Int(SUError.noUpdateError.rawValue), error.code != Int(SUError.installationCanceledError.rawValue)
        else {
            // Dismissed or skipped on the Mac, or nothing to install.
            if phase != nil { phase = nil; progress = nil }
            return
        }
        if updateCheck == .updateInformation || phase != nil { fail(error.localizedDescription) }
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows an update itself when the app is in focus anyway, such
    /// as just after launch; otherwise the menu offers it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { available = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        available = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
    }
}

/// Sparkle's standard windows, except while the web UI installs an update
/// (`AppUpdater.phase` is set): then it answers Sparkle itself, so nothing
/// waits for a click on the Mac, and reports progress to the web UI.
@MainActor
final class UpdateDriver: NSObject, @preconcurrency SPUUserDriver {
    let standard: SPUStandardUserDriver
    weak var owner: AppUpdater?
    /// Sparkle's question while the standard driver offers an update, so the
    /// web UI can answer it instead.
    private var offer: Reply?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    /// Answers once: from whichever of the standard driver and the web UI
    /// gets there first.
    private final class Reply {
        private var reply: ((SPUUserUpdateChoice) -> Void)?
        init(_ reply: @escaping (SPUUserUpdateChoice) -> Void) { self.reply = reply }
        func take() -> ((SPUUserUpdateChoice) -> Void)? {
            defer { reply = nil }
            return reply
        }
    }

    init(standard: SPUStandardUserDriver) {
        self.standard = standard
    }

    private var headless: Bool { owner?.phase != nil }

    /// Installs the update the standard driver is offering, if it is offering one.
    func takeOver() -> Bool {
        guard let reply = offer?.take() else { return false }
        offer = nil
        owner?.phase = .downloading
        // Its window, if open, would otherwise stay; the reply is taken, so closing it can't dismiss the update.
        standard.dismissUpdateInstallation()
        reply(.install)
        return true
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if headless { owner?.phase = .checking } else { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard headless else {
            let offer = Reply(reply)
            self.offer = offer
            standard.showUpdateFound(with: appcastItem, state: state) { choice in offer.take()?(choice) }
            return
        }
        if appcastItem.isInformationOnlyUpdate {
            reply(.dismiss)
            owner?.fail("Proxmacs \(appcastItem.displayVersionString) can only be downloaded from its release page")
            return
        }
        owner?.phase = state.stage == .installing ? .installing : .downloading
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if !headless { standard.showUpdateReleaseNotes(with: downloadData) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        if !headless { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard headless else { return standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
        owner?.found = nil
        owner?.phase = nil
        owner?.progress = nil
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard headless else { return standard.showUpdaterError(error, acknowledgement: acknowledgement) }
        owner?.fail(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard headless else { return standard.showDownloadInitiated(cancellation: cancellation) }
        expected = 0
        received = 0
        owner?.phase = .downloading
        owner?.progress = nil
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard headless else { return standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
        expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard headless else { return standard.showDownloadDidReceiveData(ofLength: length) }
        received += length
        if expected > 0 { owner?.progress = min(1, Double(received) / Double(expected)) }
    }

    func showDownloadDidStartExtractingUpdate() {
        guard headless else { return standard.showDownloadDidStartExtractingUpdate() }
        owner?.phase = .extracting
        owner?.progress = nil
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard headless else { return standard.showExtractionReceivedProgress(progress) }
        owner?.progress = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard headless else { return standard.showReady(toInstallAndRelaunch: reply) }
        owner?.phase = .installing
        owner?.progress = nil
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        guard headless else {
            return standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                                 retryTerminatingApplication: retryTerminatingApplication)
        }
        owner?.phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        guard headless else { return standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
        acknowledgement()
    }

    func showUpdateInFocus() {
        if !headless { standard.showUpdateInFocus() }
    }

    func dismissUpdateInstallation() {
        offer = nil
        if headless {
            owner?.phase = nil
            owner?.progress = nil
        }
        standard.dismissUpdateInstallation()
    }
}
