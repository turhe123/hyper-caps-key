import Foundation

/// Applies and removes the system-wide `UserKeyMapping` (the same property `hidutil` manages) that turns
/// Caps Lock into F18 on every keyboard. The user's previous mapping is persisted before we touch it, so
/// it can be restored on disable, on quit, or on the next launch after a crash.
enum KeyMapper {
    static let capsLockUsage: Int64 = 0x7_0000_0039
    static let f18Usage: Int64 = 0x7_0000_006D

    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"
    private static let savedDefaultsKey = "savedUserKeyMapping"
    private static let appliedDefaultsKey = "userKeyMappingApplied"
    private static var defaults: UserDefaults { .standard }

    typealias Mapping = [[String: Int64]]

    /// Maps Caps Lock → F18 for all keyboards. Returns `false` if the mapping could not be set.
    @discardableResult
    static func apply() -> Bool {
        let previous: Mapping
        if defaults.bool(forKey: appliedDefaultsKey) {
            previous = savedMapping()
        } else {
            guard let current = currentMapping() else { return false }
            previous = current.filter { !isOurs($0) }
            defaults.set(previous, forKey: savedDefaultsKey)
        }
        let ours: [String: Int64] = [srcKey: capsLockUsage, dstKey: f18Usage]
        let combined = previous.filter { $0[srcKey] != capsLockUsage } + [ours]
        guard set(combined) else { return false }
        defaults.set(true, forKey: appliedDefaultsKey)
        return true
    }

    /// Puts back whatever mapping existed before we applied ours. Safe to call at any time.
    static func restore() {
        guard defaults.bool(forKey: appliedDefaultsKey) else { return }
        if set(savedMapping()) {
            defaults.set(false, forKey: appliedDefaultsKey)
            defaults.removeObject(forKey: savedDefaultsKey)
        }
    }

    /// Called at launch: if a previous run died with the mapping applied, undo it.
    static func recoverIfNeeded() { restore() }

    private static func isOurs(_ entry: [String: Int64]) -> Bool {
        entry[srcKey] == capsLockUsage && entry[dstKey] == f18Usage
    }

    private static func savedMapping() -> Mapping {
        (defaults.array(forKey: savedDefaultsKey) as? Mapping) ?? []
    }

    private static func currentMapping() -> Mapping? {
        guard let output = hidutil(["property", "--get", "UserKeyMapping"]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(null)" { return [] }
        guard let data = trimmed.data(using: .utf8),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return list.compactMap { item in
            guard let src = (item[srcKey] as? NSNumber)?.int64Value,
                  let dst = (item[dstKey] as? NSNumber)?.int64Value else { return nil }
            return [srcKey: src, dstKey: dst]
        }
    }

    private static func set(_ mapping: Mapping) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": mapping]),
              let json = String(data: data, encoding: .utf8) else { return false }
        return hidutil(["property", "--set", json]) != nil
    }

    /// Runs `/usr/bin/hidutil` and returns stdout, or `nil` on failure.
    private static func hidutil(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
