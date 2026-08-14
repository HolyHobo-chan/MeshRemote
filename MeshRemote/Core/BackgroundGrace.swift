import Foundation
import UIKit

/// Holds a background task assertion while the app is off screen, which keeps
/// the process running for the short grace period iOS grants (on the order of
/// 30 seconds) instead of suspending it immediately.
///
/// That window is what makes a quick trip to a password manager or authenticator
/// survivable: the process stays alive, so the control socket *and* any open
/// desktop/terminal/SSH tunnels are still connected when the user comes back —
/// no reconnect, no lost session. Once iOS calls time, the assertion is released
/// and the app suspends normally; `MeshServerConnection.refreshAfterForeground`
/// then redials on the next launch into the foreground.
///
/// This is the standard "let me finish what I was doing" API, not a background
/// mode — no entitlements, and nothing that misrepresents what the app does.
final class BackgroundGrace {
    private var taskId: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    func begin() {
        guard taskId == .invalid else { return }
        taskId = UIApplication.shared.beginBackgroundTask(withName: "MeshRemote Session") { [weak self] in
            // iOS is out of patience. The assertion has to be released before this
            // handler returns or the app is killed outright rather than suspended,
            // so release synchronously instead of hopping onto a queue. UIKit
            // calls this handler on the main thread.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    @MainActor
    func end() {
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
    }
}
