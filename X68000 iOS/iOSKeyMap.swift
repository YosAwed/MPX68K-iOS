//
//  iOSKeyMap.swift
//  MPX68K for iOS
//
//  Maps hardware keyboard input to the key codes accepted by
//  X68000_Key_Down / X68000_Key_Up, which index KeyTable in
//  px68k/x11/keyboard.c:
//  - 0x00-0x7f: an ASCII character → the X68000 (JIS) key engraved with it
//  - 0x100-0x1ff: special keys (arrows, function keys, modifiers, keypad)
//
//  Printable characters are mapped by the character the host keyboard
//  produced (so US and JIS host layouts both type what is printed on the
//  keycap), together with whether the X68000 JIS layout needs SHIFT for it.
//

import UIKit

enum iOSKeyMap {

    /// KeyTable index of the left SHIFT key.
    static let shiftKey: UInt32 = 0x1e1

    struct CharacterKey {
        let code: UInt32
        let shift: Bool
    }

    // MARK: - Special keys (position based)

    static func specialKeyCode(for usage: UIKeyboardHIDUsage) -> UInt32? {
        specialKeys[usage]
    }

    static func isShift(_ usage: UIKeyboardHIDUsage) -> Bool {
        usage == .keyboardLeftShift || usage == .keyboardRightShift
    }

    private static let specialKeys: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardReturnOrEnter: 0x0d,
        .keyboardDeleteOrBackspace: 0x08,
        .keyboardTab: 0x09,
        .keyboardEscape: 0x1b,
        .keyboardSpacebar: 0x20,

        .keyboardUpArrow: 0x111,
        .keyboardDownArrow: 0x112,
        .keyboardRightArrow: 0x113,
        .keyboardLeftArrow: 0x114,

        .keyboardHome: 0x150,
        .keyboardPageDown: 0x155,       // ROLL DOWN
        .keyboardPageUp: 0x156,         // ROLL UP
        .keyboardEnd: 0x157,            // UNDO
        .keyboardInsert: 0x162,
        .keyboardDeleteForward: 0x1ff,

        .keyboardF1: 0x1be, .keyboardF2: 0x1bf, .keyboardF3: 0x1c0, .keyboardF4: 0x1c1,
        .keyboardF5: 0x1c2, .keyboardF6: 0x1c3, .keyboardF7: 0x1c4, .keyboardF8: 0x1c5,
        .keyboardF9: 0x1c6, .keyboardF10: 0x1c7,

        .keyboardLeftShift: 0x1e1,
        .keyboardRightShift: 0x1e2,
        .keyboardLeftControl: 0x1e3,
        .keyboardRightControl: 0x1e4,
        .keyboardCapsLock: 0x1e5,
        .keyboardLeftAlt: 0x1e9,        // XF1
        .keyboardRightAlt: 0x1ea,       // XF1

        .keypadAsterisk: 0x1aa,
        .keypadPlus: 0x1ab,
        .keypadHyphen: 0x1ad,
        .keypadPeriod: 0x1ae,
        .keypadSlash: 0x1af,
        .keypad0: 0x1b0, .keypad1: 0x1b1, .keypad2: 0x1b2, .keypad3: 0x1b3, .keypad4: 0x1b4,
        .keypad5: 0x1b5, .keypad6: 0x1b6, .keypad7: 0x1b7, .keypad8: 0x1b8, .keypad9: 0x1b9,
        .keypadEnter: 0x0d,
    ]

    /// JIS-only keys whose character may not come through with a US host layout.
    static func jisKeyCode(for usage: UIKeyboardHIDUsage) -> UInt32? {
        switch usage {
        case .keyboardInternational3: return 0x5c   // ¥ key
        case .keyboardInternational1: return 0x5f   // ろ key (_)
        default: return nil
        }
    }

    // MARK: - Printable characters (character based)

    static func characterKey(for character: Character) -> CharacterKey? {
        if let key = symbolKeys[character] {
            return key
        }
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x30...0x39, 0x61...0x7a:      // 0-9, a-z
            return CharacterKey(code: UInt32(ascii), shift: false)
        case 0x41...0x5a:                   // A-Z
            return CharacterKey(code: UInt32(ascii + 0x20), shift: true)
        default:
            return nil
        }
    }

    /// Symbols on the X68000 JIS keyboard: base key character and SHIFT state.
    private static let symbolKeys: [Character: CharacterKey] = {
        func key(_ base: Character, shift: Bool) -> CharacterKey {
            CharacterKey(code: UInt32(base.asciiValue!), shift: shift)
        }
        return [
            "!": key("1", shift: true),
            "\"": key("2", shift: true),
            "#": key("3", shift: true),
            "$": key("4", shift: true),
            "%": key("5", shift: true),
            "&": key("6", shift: true),
            "'": key("7", shift: true),
            "(": key("8", shift: true),
            ")": key("9", shift: true),
            "-": key("-", shift: false),
            "=": key("-", shift: true),
            "^": key("^", shift: false),
            "~": key("^", shift: true),
            "\\": key("\\", shift: false),
            "¥": key("\\", shift: false),
            "|": key("\\", shift: true),
            "@": key("@", shift: false),
            "`": key("@", shift: true),
            "[": key("[", shift: false),
            "{": key("[", shift: true),
            ";": key(";", shift: false),
            "+": key(";", shift: true),
            ":": key(":", shift: false),
            "*": key(":", shift: true),
            "]": key("]", shift: false),
            "}": key("]", shift: true),
            ",": key(",", shift: false),
            "<": key(",", shift: true),
            ".": key(".", shift: false),
            ">": key(".", shift: true),
            "/": key("/", shift: false),
            "?": key("/", shift: true),
            "_": key("_", shift: true),
            " ": key(" ", shift: false),
        ]
    }()
}
