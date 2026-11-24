import Foundation

#if canImport(Sparkle)
import Sparkle

/// In-app updates for the DMG build (Sparkle). Source and Homebrew builds have no Sparkle and update with brew.
/// Feed: SUFeedURL in Info.plist. Every update is checked against SUPublicEDKey before it is installed.
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()
    static let available = true
    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() { _ = controller }
    func checkNow() { controller.checkForUpdates(nil) }

    /// Never quit for an update in the middle of a meeting: wait until the recording stops and its notes are made.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Also wait while notes are being made after the meeting, or the relaunch would kill that job.
        func busy() -> Bool { AppDelegate.model.isRecording || !AppDelegate.model.busy.isEmpty }
        guard busy() else { return false }
        func wait() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                busy() ? wait() : installHandler()
            }
        }
        wait()
        return true
    }
}
#else
final class Updater {
    static let shared = Updater()
    static let available = false
    func start() {}
    func checkNow() {}
}
#endif
