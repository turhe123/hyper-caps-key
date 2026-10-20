# HyperCapsKey — specification

**Tagline:** Turn Caps Lock into a Hyper key that fires Command, Option, Control and Shift together for your shortcuts.

**Category:** Text & Input

**Inspired by (paid):** Hyperkey ($19 one-time)

**Frameworks:** SwiftUI, AppKit, CoreGraphics, ApplicationServices, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: Hyperkey remaps Caps Lock or another spare key into a Hyper modifier, meaning Command, Option, Control and Shift held at once, so power users get a huge namespace of conflict-free global shortcuts for launchers, window tools and text expanders. It sells for about nineteen dollars one time and is repeatedly recommended in Mac productivity threads and launcher communities. Our clean-room version covers the same core idea without any account.

Feature set: pick a source key from Caps Lock, Right Command, Right Option or Right Control. While the source key is held, every other key press is delivered with all four modifier flags added. A quick tap with no other key can optionally send Escape or do nothing. Include an option to also add the Hyper flags only while held versus latching on for the next key press. Include a Test pad in settings that shows the last key event and the flags it carried. Keep everything within roughly three hundred lines.

UI spec: a MenuBarExtra with a keyboard glyph that fills when Hyper is active. The menu has an Enabled toggle, a Quick tap action submenu, Open Settings, and Quit. The settings window has a source key picker, a tap behavior picker, a launch at login checkbox, an Accessibility status row with a Grant button, and the test pad. Empty state: if Accessibility permission is missing, the menu shows a single Grant Accessibility item and the remap stays off.

Technical approach: Caps Lock cannot be seen reliably by an event tap while it acts as a lock, so on enable we use the hidutil style user key mapping through the IOHIDEventSystemClient property for the keyboard service, mapping Caps Lock to a rarely used function key code such as F18. Where that is not available we fall back to treating Right Command through the flags changed events. A CGEventTap at the session level, created with CGEvent.tapCreate and listening for key down, key up and flags changed, watches for the source key. When it is held, we set the maskCommand, maskAlternate, maskControl and maskShift flags on every other key event and pass it on. Request trust with AXIsProcessTrustedWithOptions and show the prompt once. Persist choices with AppStorage. Register launch at login using SMAppService mainApp. On quit or disable, remove the key mapping so the keyboard returns to normal.

Edge cases: if the event tap is disabled by the system because of a timeout, re-enable it from the tap callback on the disabled by timeout event type. Key repeat while holding must not re-trigger tap behavior. Secure input fields such as password boxes may block taps, so show a gentle note. Always restore the original mapping if the app crashes by storing the previous mapping state and re-checking at launch. Multiple keyboards should all be covered. Handle sleep and wake by reapplying the mapping. Never log typed characters, only key codes in the test pad, and clear the pad when it is closed.
