import AppKit
import ApplicationServices
import CoreGraphics

/// The physical key that acts as Hyper while held.
enum SourceKey: String, CaseIterable, Identifiable {
    case capsLock, rightCommand, rightOption, rightControl
    var id: String { rawValue }

    var title: String {
        switch self {
        case .capsLock: "Caps Lock"
        case .rightCommand: "Right Command"
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        }
    }

    /// Virtual key code the event tap sees (Caps Lock arrives as F18 after remapping).
    var keyCode: Int64 {
        switch self {
        case .capsLock: 79
        case .rightCommand: 54
        case .rightOption: 61
        case .rightControl: 62
        }
    }

    /// Device-dependent flag bit that tells whether the right-hand modifier is down.
    var deviceMask: UInt64 {
        switch self {
        case .capsLock: 0
        case .rightCommand: 0x10
        case .rightOption: 0x40
        case .rightControl: 0x2000
        }
    }
}

/// What a quick tap of the source key (with no other key pressed) does.
enum TapAction: String, CaseIterable, Identifiable {
    case escape, nothing
    var id: String { rawValue }
    var title: String { self == .escape ? "Send Escape" : "Do Nothing" }
}

/// Whether Hyper applies only while held, or latches for the next key after a tap.
enum HyperMode: String, CaseIterable, Identifiable {
    case hold, latch
    var id: String { rawValue }
    var title: String { self == .hold ? "While held" : "Latch for next key" }
}

/// A key event shown in the test pad. Only key codes and modifier flags — never characters.
struct KeyEventInfo: Equatable {
    let kind: String
    let keyCode: Int64
    let flags: String
}

/// Owns the CGEventTap, the Caps Lock remapping and the user's settings, and adds the four Hyper
/// modifier flags to every key event while the source key is held (or latched).
final class HyperEngine: ObservableObject {
    static let hyperFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    @Published var enabled: Bool { didSet { save(enabled, "enabled"); refresh() } }
    @Published var sourceKey: SourceKey { didSet { save(sourceKey.rawValue, "sourceKey"); refresh(restart: true) } }
    @Published var tapAction: TapAction { didSet { save(tapAction.rawValue, "tapAction") } }
    @Published var mode: HyperMode { didSet { save(mode.rawValue, "mode"); latched = false; updateActive() } }

    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var running = false
    @Published private(set) var hyperActive = false
    @Published private(set) var usingFallback = false
    @Published private(set) var lastEvent: KeyEventInfo?

    /// The test pad sets this; events are only recorded while it is visible and cleared when it closes.
    var testPadVisible = false { didSet { if !testPadVisible { lastEvent = nil } } }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeSource: SourceKey = .capsLock
    private var held = false
    private var usedWhileHeld = false
    private var latched = false
    private var hyperKeyUps = Set<Int64>()
    private var trustTimer: Timer?

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        sourceKey = SourceKey(rawValue: d.string(forKey: "sourceKey") ?? "") ?? .capsLock
        tapAction = TapAction(rawValue: d.string(forKey: "tapAction") ?? "") ?? .escape
        mode = HyperMode(rawValue: d.string(forKey: "mode") ?? "") ?? .hold

        KeyMapper.recoverIfNeeded()
        if !trusted && !d.bool(forKey: "promptedForTrust") {
            d.set(true, forKey: "promptedForTrust")
            promptForTrust()
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkTrust()
        }
        refresh()
    }

    // MARK: Permissions

    func requestAccessibility() {
        promptForTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
    }

    private func checkTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        refresh()
    }

    // MARK: Lifecycle

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    /// Starts or stops the remap so it matches `enabled` and the Accessibility state.
    private func refresh(restart: Bool = false) {
        if enabled && trusted {
            if !running || restart { start() }
        } else {
            stop()
        }
    }

    private func start() {
        stop()
        activeSource = sourceKey
        usingFallback = false
        if sourceKey == .capsLock && !KeyMapper.apply() {
            activeSource = .rightCommand
            usingFallback = true
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: hyperTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            KeyMapper.restore()
            return
        }
        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        running = true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        KeyMapper.restore()
        held = false
        latched = false
        hyperKeyUps.removeAll()
        running = false
        updateActive()
    }

    private func handleWake() {
        guard running else { return }
        if activeSource == .capsLock { KeyMapper.apply() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: Event handling

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if code == activeSource.keyCode {
            if activeSource == .capsLock && (type == .keyDown || type == .keyUp) {
                if type == .keyUp {
                    sourceUp()
                } else if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    sourceDown()
                }
                return nil
            }
            if activeSource != .capsLock && type == .flagsChanged {
                event.flags.rawValue & activeSource.deviceMask != 0 ? sourceDown() : sourceUp()
                return Unmanaged.passUnretained(event)
            }
        }

        if type == .keyDown || type == .keyUp {
            var apply = held || hyperKeyUps.contains(code)
            if type == .keyDown && !apply && latched {
                apply = true
                latched = false
                updateActive()
            }
            if apply {
                event.flags.formUnion(Self.hyperFlags)
                if type == .keyDown {
                    usedWhileHeld = true
                    hyperKeyUps.insert(code)
                } else {
                    hyperKeyUps.remove(code)
                }
            }
        }
        record(type, event, code)
        return Unmanaged.passUnretained(event)
    }

    private func sourceDown() {
        guard !held else { return }
        held = true
        usedWhileHeld = false
        updateActive()
    }

    private func sourceUp() {
        guard held else { return }
        held = false
        if !usedWhileHeld {
            if mode == .latch {
                latched.toggle()
            } else if tapAction == .escape {
                postEscape()
            }
        }
        updateActive()
    }

    private func updateActive() {
        let active = held || latched
        if hyperActive != active { hyperActive = active }
    }

    private func postEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private func record(_ type: CGEventType, _ event: CGEvent, _ code: Int64) {
        guard testPadVisible else { return }
        let kind = type == .keyDown ? "Key Down" : type == .keyUp ? "Key Up" : "Flags Changed"
        let f = event.flags
        let symbols: [(CGEventFlags, String)] = [
            (.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"),
            (.maskCommand, "⌘"), (.maskAlphaShift, "⇪"), (.maskSecondaryFn, "fn"),
        ]
        let text = symbols.filter { f.contains($0.0) }.map(\.1).joined(separator: " ")
        lastEvent = KeyEventInfo(kind: kind, keyCode: code, flags: text.isEmpty ? "none" : text)
    }
}

/// C-compatible tap callback that forwards to the engine passed in `userInfo`.
private func hyperTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<HyperEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handle(type, event)
}
