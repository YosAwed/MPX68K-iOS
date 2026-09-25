//
//  iOSKeyMap.swift
//  MPX68K for iOS
//
//  Maps hardware keyboard HID usages to the key codes accepted by
//  X68000_Key_Down / X68000_Key_Up (ported from the former iOS
//  GameViewController.iOStoX68 table).
//

import UIKit

enum iOSKeyMap {
    static func x68KeyCode(for usage: UIKeyboardHIDUsage) -> UInt32? {
        table[usage]
    }

    private static let table: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardReturnOrEnter: 0x0d,
        .keyboardDeleteOrBackspace: 0x08,
        .keyboardSpacebar: 0x20,
        .keyboardEscape: 0xff,          // [HELP]
        .keyboardTab: 0xfe,             // [登録]

        .keyboardEqualSign: 0x40,       // +
        .keyboardComma: 0x2c,
        .keyboardHyphen: 0x2d,
        .keyboardPeriod: 0x2e,
        .keyboardSlash: 0x2f,
        .keyboardSemicolon: 0x3a,
        .keyboardQuote: 0x2b,

        .keyboardLeftShift: 0x130,
        .keyboardRightShift: 0x130,
        .keyboardLeftControl: 0x1e3,
        .keyboardRightControl: 0x1e3,

        .keyboard0: 0x30, .keyboard1: 0x31, .keyboard2: 0x32, .keyboard3: 0x33, .keyboard4: 0x34,
        .keyboard5: 0x35, .keyboard6: 0x36, .keyboard7: 0x37, .keyboard8: 0x38, .keyboard9: 0x39,

        .keyboardA: 0x41, .keyboardB: 0x42, .keyboardC: 0x43, .keyboardD: 0x44, .keyboardE: 0x45,
        .keyboardF: 0x46, .keyboardG: 0x47, .keyboardH: 0x48, .keyboardI: 0x49, .keyboardJ: 0x4a,
        .keyboardK: 0x4b, .keyboardL: 0x4c, .keyboardM: 0x4d, .keyboardN: 0x4e, .keyboardO: 0x4f,
        .keyboardP: 0x50, .keyboardQ: 0x51, .keyboardR: 0x52, .keyboardS: 0x53, .keyboardT: 0x54,
        .keyboardU: 0x55, .keyboardV: 0x56, .keyboardW: 0x57, .keyboardX: 0x58, .keyboardY: 0x59,
        .keyboardZ: 0x5a,
        .keyboardOpenBracket: 0x5b,
        .keyboardBackslash: 0x5c,
        .keyboardCloseBracket: 0x5d,
        .keyboardGraveAccentAndTilde: 0x7e,

        .keyboardUpArrow: 0x111,
        .keyboardDownArrow: 0x112,
        .keyboardRightArrow: 0x113,
        .keyboardLeftArrow: 0x114,

        .keyboardF1: 0x1be, .keyboardF2: 0x1bf, .keyboardF3: 0x1c0, .keyboardF4: 0x1c1,
        .keyboardF5: 0x1c2, .keyboardF6: 0x1c3, .keyboardF7: 0x1c4, .keyboardF8: 0x1c5,
        .keyboardF9: 0x1c6, .keyboardF10: 0x1c7, .keyboardF11: 0x1c8, .keyboardF12: 0x1c9,

        .keyboardCapsLock: 0xe5,
        .keyboardInsert: 0x15a,
        .keyboardHome: 0x150,
        .keyboardEnd: 0x158,
        .keyboardPageUp: 0x157,
        .keyboardPageDown: 0x156,
        .keyboardLeftAlt: 0xff,         // [HELP]
        .keyboardRightAlt: 0xfe,        // [登録]
    ]
}
