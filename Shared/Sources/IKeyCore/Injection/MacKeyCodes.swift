import Foundation

/// CGEventFlags bit layout (generic bits plus the NX_DEVICE* left/right bits), kept as a
/// platform-neutral option set so the keyboard model can be tested on Linux.
public struct ModifierFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let alphaShift = ModifierFlags(rawValue: 0x10000), shift = ModifierFlags(rawValue: 0x20000),
        control = ModifierFlags(rawValue: 0x40000), option = ModifierFlags(rawValue: 0x80000),
        command = ModifierFlags(rawValue: 0x100000), numericPad = ModifierFlags(rawValue: 0x200000),
        help = ModifierFlags(rawValue: 0x400000), secondaryFn = ModifierFlags(rawValue: 0x800000),
        nonCoalesced = ModifierFlags(rawValue: 0x100),
        leftControl = ModifierFlags(rawValue: 0x1), leftShift = ModifierFlags(rawValue: 0x2),
        rightShift = ModifierFlags(rawValue: 0x4), leftCommand = ModifierFlags(rawValue: 0x8),
        rightCommand = ModifierFlags(rawValue: 0x10), leftOption = ModifierFlags(rawValue: 0x20),
        rightOption = ModifierFlags(rawValue: 0x40), rightControl = ModifierFlags(rawValue: 0x2000)
}

/// macOS virtual key codes (kVK_*) the keyboard model treats specially.
public enum MacKeyCode {
    public static let fn: UInt16 = 63
    public static let capsLock: UInt16 = 57

    /// Codes that post flagsChanged: the eight sided modifiers plus fn. Caps Lock is handled
    /// by `CapsLockController` and is not included.
    public static let modifiers: Set<UInt16> = Set(modifierTable.keys)

    /// Physical F1...F12 in top-row order (F1 first).
    public static let fKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// Generic | device bit for a modifier code, secondaryFn for fn, nil for anything else.
    public static func modifierFlags(for code: UInt16) -> ModifierFlags? { modifierTable[code] }

    /// Flags the HID keyboard filter adds to a key event because of the key itself.
    public static func implicitFlags(for code: UInt16) -> ModifierFlags {
        if arrowKeys.contains(code) { return [.secondaryFn, .numericPad] }
        if functionKeys.contains(code) || navigationKeys.contains(code) { return .secondaryFn }
        if keypadKeys.contains(code) { return .numericPad }
        return []
    }

    private static let modifierTable: [UInt16: ModifierFlags] = [
        56: [.shift, .leftShift], 60: [.shift, .rightShift],
        59: [.control, .leftControl], 62: [.control, .rightControl],
        58: [.option, .leftOption], 61: [.option, .rightOption],
        55: [.command, .leftCommand], 54: [.command, .rightCommand],
        63: .secondaryFn
    ]
    private static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]
    // F1-F20.
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                    105, 107, 113, 106, 64, 79, 80, 90]
    // Help, Home, Page Up, Forward Delete, End, Page Down.
    private static let navigationKeys: Set<UInt16> = [114, 115, 116, 117, 119, 121]
    private static let keypadKeys: Set<UInt16> = Set<UInt16>([65, 67, 69, 71, 75, 76, 78, 91, 92]).union(81...89)
}
