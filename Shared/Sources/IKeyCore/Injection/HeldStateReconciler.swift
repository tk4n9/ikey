import Foundation

/// Compares what the Mac holds with the iPad's heartbeat snapshot. It only ever releases:
/// a key or button the iPad holds but the Mac does not is never pressed, and Caps Lock (57)
/// is left to its own controller.
public struct HeldStateReconciler: Sendable {
    /// Keys to release (non-modifiers ascending, then modifiers ascending, so a stale
    /// letter goes up while its modifiers still apply) and buttons to release (left first).
    public static func reconcile(macHeldKeys: Set<UInt16>, macButtons: Set<PointerButton>, padHeld: Set<UInt16>,
                                 padButtons: Set<PointerButton>) -> (releaseKeys: [UInt16], releaseButtons: [PointerButton]) {
        let stale = macHeldKeys.subtracting(padHeld).subtracting([MacKeyCode.capsLock])
        let keys = stale.filter { !MacKeyCode.modifiers.contains($0) }.sorted()
            + stale.filter { MacKeyCode.modifiers.contains($0) }.sorted()
        let buttons = [PointerButton.left, .right].filter { macButtons.contains($0) && !padButtons.contains($0) }
        return (keys, buttons)
    }
}
