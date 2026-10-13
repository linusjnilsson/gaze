import AppKit
import CoreGraphics
import Foundation

/// What switches focus to where the user looks. Several kinds, to find what feels natural:
/// a modifier tapped alone (shortcuts are chords, and a chord cancels), a modifier double-tapped,
/// Caps Lock, or a mouse button.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand, rightOption, rightControl, rightShift
    case leftCommand, leftOption, function
    case doubleLeftCommand, doubleOption, doubleControl, doubleCommand
    case capsLock
    case middleButton, backButton, forwardButton

    var id: String { rawValue }

    enum Kind: Equatable {
        /// A modifier key pressed and released alone. `deviceMask` tells left from right
        /// (IOKit's NX_DEVICE*KEYMASK); `nil` for keys without a twin.
        case tap(keyCode: UInt16, flag: NSEvent.ModifierFlags, deviceMask: UInt?)
        /// Either key of a modifier, tapped twice in quick succession.
        case doubleTap(flag: NSEvent.ModifierFlags, deviceMask: UInt? = nil)
        /// Caps Lock, remapped while selected to a key that does nothing else.
        case capsLock
        /// A mouse button (2 = middle, 3 = back, 4 = forward), kept from apps while selected.
        case mouse(button: Int64)
    }

    var kind: Kind {
        switch self {
        case .rightCommand: .tap(keyCode: 54, flag: .command, deviceMask: 0x10)
        case .rightOption: .tap(keyCode: 61, flag: .option, deviceMask: 0x40)
        case .rightControl: .tap(keyCode: 62, flag: .control, deviceMask: 0x2000)
        case .rightShift: .tap(keyCode: 60, flag: .shift, deviceMask: 0x04)
        case .leftCommand: .tap(keyCode: 55, flag: .command, deviceMask: 0x08)
        case .leftOption: .tap(keyCode: 58, flag: .option, deviceMask: 0x20)
        case .function: .tap(keyCode: 63, flag: .function, deviceMask: nil)
        case .doubleLeftCommand: .doubleTap(flag: .command, deviceMask: 0x08)
        case .doubleOption: .doubleTap(flag: .option)
        case .doubleControl: .doubleTap(flag: .control)
        case .doubleCommand: .doubleTap(flag: .command)
        case .capsLock: .capsLock
        case .middleButton: .mouse(button: 2)
        case .backButton: .mouse(button: 3)
        case .forwardButton: .mouse(button: 4)
        }
    }

    var label: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        case .rightShift: "Right ⇧"
        case .leftCommand: "Left ⌘"
        case .leftOption: "Left ⌥"
        case .function: "🌐 / fn"
        case .doubleLeftCommand: "Double-tap left ⌘"
        case .doubleOption: "Double-tap ⌥"
        case .doubleControl: "Double-tap ⌃"
        case .doubleCommand: "Double-tap ⌘"
        case .capsLock: "Caps Lock"
        case .middleButton: "Middle mouse button"
        case .backButton: "Mouse back button"
        case .forwardButton: "Mouse forward button"
        }
    }

    /// How to use it, completing "Look at a window and …".
    var action: String {
        switch kind {
        case .tap, .capsLock: "tap \(label)"
        case .doubleTap(let flag, let deviceMask): "double-tap \(deviceMask != nil ? "left " : "")\(flag == .option ? "⌥" : flag == .control ? "⌃" : "⌘")"
        case .mouse: "click the \(label.lowercased())"
        }
    }

    /// Held with the trigger, opens the overview of all windows.
    var overviewKey: String { self == .rightShift ? "left ⇧" : "⇧" }

    /// What to know before trying it.
    var note: String? {
        switch self {
        case .function: "Set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”, or it also opens emoji or switches input."
        case .leftCommand: "A ⌘ pressed and let go without a shortcut also switches."
        case .capsLock: "Caps Lock no longer types capitals while this is selected; it's restored when you pick another trigger or quit Gaze."
        case .middleButton, .backButton, .forwardButton: "Apps no longer receive this button while it's selected."
        default: nil
        }
    }

    /// Groups for the picker.
    static let groups: [(String, [TriggerKey])] = [
        ("Tap alone", [.rightCommand, .rightOption, .rightControl, .rightShift, .leftCommand, .leftOption, .function, .capsLock]),
        ("Double-tap", [.doubleLeftCommand, .doubleCommand, .doubleOption, .doubleControl]),
        ("Mouse", [.middleButton, .backButton, .forwardButton]),
    ]
}

extension TriggerKey {
    /// The modifier keys usable as the pane trigger: tapped alone or double-tapped (Caps Lock and
    /// mouse buttons belong to the window trigger), and not on the window trigger's modifier,
    /// whose taps would count for both.
    static func paneOptions(besides window: TriggerKey) -> [(String, [TriggerKey])] {
        groups.compactMap { title, keys in
            let usable = keys.filter { key in
                guard let flag = key.modifierFlag else { return false }
                return flag != window.modifierFlag
            }
            return usable.isEmpty ? nil : (title, usable)
        }
    }

    var modifierFlag: NSEvent.ModifierFlags? {
        switch kind {
        case .tap(_, let flag, _), .doubleTap(let flag, _): flag
        case .capsLock, .mouse: nil
        }
    }
}

/// Recognizes a modifier trigger, tapped alone or double-tapped, from modifier changes. The
/// armed state is the owner's: it can also be cancelled by other input.
struct ModifierTrigger {
    enum Action { case arm, commit, cancel }

    var key: TriggerKey
    /// Double-tap state: whether the modifier is down, and the first tap of a pair.
    private var doubleTapKeyDown = false
    private var firstTap: (pressed: TimeInterval, released: TimeInterval?)?

    /// The second press of a double-tap must follow the first release within this, and each tap
    /// be shorter than `tapDuration`.
    static let doubleTapGap = 0.35
    static let tapDuration = 0.3

    init(_ key: TriggerKey) {
        self.key = key
    }

    mutating func modifiersChanged(_ event: NSEvent, armed: Bool) -> Action? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        switch key.kind {
        case let .tap(keyCode, flag, deviceMask):
            let isDown = deviceMask.map { event.modifierFlags.rawValue & $0 != 0 } ?? modifiers.contains(flag)
            if event.keyCode == keyCode, isDown, modifiers == flag { return .arm }
            if armed, event.keyCode == keyCode, !isDown { return .commit }
            // Another modifier joined in.
            return armed ? .cancel : nil
        case let .doubleTap(flag, deviceMask):
            let isDown = deviceMask.map { event.modifierFlags.rawValue & $0 != 0 } ?? modifiers.contains(flag)
            return doubleTap(flag: flag, isDown: isDown, modifiers: modifiers, at: event.timestamp, armed: armed)
        case .capsLock, .mouse:
            return armed ? .cancel : nil
        }
    }

    /// Any other key or click: a chord, or typing between taps.
    mutating func otherInput() {
        firstTap = nil
    }

    /// Two quick taps of the modifier alone; holding the second arms, and releasing it commits.
    /// `isDown` is that key's state (for a one-sided trigger, the other side's key doesn't count).
    private mutating func doubleTap(flag: NSEvent.ModifierFlags, isDown: Bool, modifiers: NSEvent.ModifierFlags, at time: TimeInterval, armed: Bool) -> Action? {
        if isDown, !doubleTapKeyDown {
            doubleTapKeyDown = true
            guard modifiers == flag else {
                firstTap = nil
                return nil
            }
            if let released = firstTap?.released, time - released < Self.doubleTapGap {
                firstTap = nil
                return .arm
            }
            firstTap = (time, nil)
            return nil
        } else if !isDown, doubleTapKeyDown {
            doubleTapKeyDown = false
            if armed { return .commit }
            if let first = firstTap, first.released == nil, time - first.pressed < Self.tapDuration {
                firstTap = (first.pressed, time)
            } else {
                firstTap = nil
            }
            return nil
        }
        // Another modifier changed.
        firstTap = nil
        return armed ? .cancel : nil
    }
}

/// Takes one mouse button away from apps and reports its presses, through an event tap
/// (needs Accessibility access).
@MainActor
final class MouseButtonTap {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Whether to take the button right now; otherwise it goes to apps as usual.
    var shouldTake: () -> Bool = { true }
    private(set) var button: Int64?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start(button: Int64) {
        stop()
        self.button = button
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue) | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<MouseButtonTap>.fromOpaque(context).takeUnretainedValue()
                let button = event.getIntegerValueField(.mouseEventButtonNumber)
                // The tap's run loop source is on the main run loop.
                let taken = MainActor.assumeIsolated { owner.handle(type, button: button) }
                return taken ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        button = nil
    }

    /// Whether the event is taken from apps.
    private func handle(_ type: CGEventType, button: Int64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard button == self.button, shouldTake() else { return false }
        if type == .otherMouseDown { onDown?() } else { onUp?() }
        return true
    }
}

/// Remaps Caps Lock to F18, which nothing uses, through `hidutil` (no admin rights; lasts until
/// undone or logout). Undone when another trigger is picked and when Gaze quits.
enum CapsLockRemap {
    /// F18's virtual key code, as it arrives in key events.
    static let keyCode: UInt16 = 79
    private static let mapping = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#

    /// Remembered across launches, so a remap left behind by a crash is still undone.
    private static let appliedKey = "capsLockRemapApplied"

    static var isApplied: Bool { UserDefaults.standard.bool(forKey: appliedKey) }

    /// `hidutil` runs here, never on the main thread: waiting for a process there with
    /// `waitUntilExit()` spins the main run loop, and doing that inside a menu action or during
    /// launch left AppKit ignoring every click in Gaze's windows.
    private static let queue = DispatchQueue(label: "gaze.caps-lock-remap")

    /// Applies the remap, then reports on the main actor whether it did: `false` if keys are
    /// already remapped by someone else, which this would overwrite.
    static func apply(then completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let applied = applyNow()
            Task { @MainActor in completion(applied) }
        }
    }

    /// Undoes the remap. With `wait`, returns once it's done (when Gaze quits).
    static func remove(wait: Bool = false) {
        if wait { queue.sync(execute: removeNow) } else { queue.async(execute: removeNow) }
    }

    private static func applyNow() -> Bool {
        if !isApplied {
            let existing = hidutil(["property", "--get", "UserKeyMapping"]) ?? ""
            if existing.contains("HIDKeyboardModifierMapping") { return false }
        }
        guard hidutil(["property", "--set", mapping]) != nil else { return false }
        UserDefaults.standard.set(true, forKey: appliedKey)
        return true
    }

    private static func removeNow() {
        guard isApplied else { return }
        hidutil(["property", "--set", #"{"UserKeyMapping":[]}"#])
        UserDefaults.standard.set(false, forKey: appliedKey)
    }

    /// Runs `hidutil` and returns its output, blocking the calling thread without touching any run loop.
    @discardableResult
    private static func hidutil(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}
