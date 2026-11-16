import AppKit
import Sparkle
import os

/// Keeps Poly up to date without ever asking. Sparkle checks the appcast every six hours, downloads
/// a new version in the background, and hands Poly the moment to install it; Poly installs and
/// relaunches as soon as nothing is happening (`Switcher.isQuiet`), which takes a few seconds.
/// Scheduled checks never show Sparkle's windows; only **Check for Updates…** does.
///
/// An update that cannot install silently (Poly's copy is not writable by this user, so macOS
/// would ask for an administrator) waits for Check for Updates… instead of interrupting.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private var install: (() -> Void)?
    private var isQuiet: () -> Bool = { true }
    /// Release builds carry the key that update archives are signed with; other builds never update.
    private(set) var isEnabled = false

    /// Starts checking. Not in builds from Xcode or `scripts/install.sh`, which have no feed key.
    func start(isQuiet: @escaping () -> Bool) {
        self.isQuiet = isQuiet
        isEnabled = !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
        controller = SPUStandardUpdaterController(
            startingUpdater: isEnabled, updaterDelegate: self, userDriverDelegate: self)
        if !isEnabled { Log.updates.info("no update key in this build; updates are off") }
    }

    func checkForUpdates() {
        guard isEnabled else { return }
        NSApp.activateForPrompt()
        controller.checkForUpdates(nil)
    }

    // MARK: Installing quietly

    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        // Sparkle calls its delegate on the main thread.
        nonisolated(unsafe) let handler = immediateInstallHandler
        MainActor.assumeIsolated {
            Log.updates.info("downloaded \(version, privacy: .public); installing when quiet")
            install = handler
            installWhenQuiet()
        }
        return true
    }

    private func installWhenQuiet() {
        guard let install else { return }
        guard isQuiet(), NSApp.modalWindow == nil else {
            Task {
                await pause(60)
                installWhenQuiet()
            }
            return
        }
        Log.updates.info("installing update and relaunching")
        install()
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        Log.updates.error("update stopped: \(nsError.localizedDescription, privacy: .public) (\(nsError.code, privacy: .public))")
    }

    // MARK: Never interrupting

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks never bring up Sparkle's window; the update waits for Check for Updates….
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            Log.updates.info("\(version, privacy: .public) needs the person to install; waiting for Check for Updates…")
        }
    }
}
