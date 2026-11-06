import Foundation
import IOKit
import IOKit.hidsystem

/// The system Caps Lock state (the one that lights the key's LED), through IOHIDSystem.
///
/// Reading the state is reported unreliable on some Macs, so `set` reads it back and reports
/// success only when the read-back matches. One IOHIDSystem connection is opened lazily and
/// reused (the state is polled often); a failure on it is retried once on a fresh connection.
enum CapsLockHardware {
    /// Sets the lock and returns true only if the verified state equals `on`.
    static func set(_ on: Bool) -> Bool {
        withConnection { (connection: io_connect_t) -> Bool? in
            guard IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), on) == KERN_SUCCESS else { return nil }
            return state(connection).map { $0 == on }
        } ?? false
    }

    /// The current lock state; nil when IOHIDSystem cannot be reached.
    static func read() -> Bool? {
        withConnection(state)
    }

    private static let lock = NSLock()
    private static var connection: io_connect_t = 0

    private static func state(_ connection: io_connect_t) -> Bool? {
        var on = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS else { return nil }
        return on
    }

    /// Runs `body` on the shared connection. A nil result closes it; when the connection was a
    /// cached one (possibly stale), one fresh connection is opened and `body` runs again, so a
    /// call fails only when a fresh connection fails too (the spec's open-per-call semantics).
    private static func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let reused = connection != 0
        for _ in 0..<(reused ? 2 : 1) {
            if connection == 0 { connection = open() }
            guard connection != 0 else { return nil }
            if let result = body(connection) { return result }
            IOServiceClose(connection)
            connection = 0
        }
        return nil
    }

    private static func open() -> io_connect_t {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else {
            return 0
        }
        return connection
    }
}
