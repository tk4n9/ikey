import AppKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping and iKey from App Nap and timer throttling while an iPad
/// session is active, and for a grace period after it ends (so a reconnect finds the Mac
/// awake). Main-queue confined.
final class PowerActivity {
    /// The session used by the no-argument calls.
    static let sharedSession: AnyHashable = "iKey.session"
    private static let grace: TimeInterval = 600

    private var openSessions: Set<AnyHashable> = []

    private var assertionID: IOPMAssertionID?
    private var activity: NSObjectProtocol?
    private var pendingRelease: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.release() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        release()
    }

    /// Holds the sleep assertion and the latency-critical activity for `session`; cancels a
    /// pending release. Starting a session that is already open does nothing more.
    ///
    /// Sessions are tracked by identity, so a replaced session's late end (its link closes
    /// after the new session was promoted) does not release what the new session needs. Pass
    /// the session's id (ReceiverArbiter's UUID); the no-argument form is one shared session.
    func sessionStarted(_ session: AnyHashable = PowerActivity.sharedSession) {
        openSessions.insert(session)
        pendingRelease?.cancel()
        pendingRelease = nil
        if assertionID == nil {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "iKey keyboard connected" as CFString, &id) == kIOReturnSuccess {
                assertionID = id
            }
        }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "iKey input session")
        }
    }

    /// Ends `session`; once no session is open, releases everything after the grace period
    /// unless a session starts first. Ending a session that was never started is ignored.
    func sessionEnded(_ session: AnyHashable = PowerActivity.sharedSession) {
        guard openSessions.remove(session) != nil, openSessions.isEmpty else { return }
        pendingRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.release() }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }

    private func release() {
        openSessions.removeAll()
        pendingRelease?.cancel()
        pendingRelease = nil
        if let assertionID {
            IOPMAssertionRelease(assertionID)
            self.assertionID = nil
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
