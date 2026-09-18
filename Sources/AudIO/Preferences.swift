import Foundation

struct DeviceConfig: Codable, Equatable {
    /// Last seen device name, so disconnected devices can still be listed in settings
    var name: String
    var displayName: String = ""
    var emoji: String = ""
    var hidden: Bool = false

    var trimmedDisplayName: String { displayName.trimmingCharacters(in: .whitespaces) }
    var isDefault: Bool { trimmedDisplayName.isEmpty && emoji.isEmpty && !hidden }
}

extension DeviceConfig {
    // Tolerates fields added since the config was saved
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

// Persists per-device renames/hiding (keyed by device UID and direction) and the global shortcut
@MainActor
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private var devices: [String: DeviceConfig]

    private init() {
        devices = defaults.data(forKey: "devices")
            .flatMap { try? JSONDecoder().decode([String: DeviceConfig].self, from: $0) } ?? [:]
    }

    private static func key(_ uid: String, _ direction: Direction) -> String {
        "\(direction.rawValue):\(uid)"
    }

    func config(uid: String, _ direction: Direction) -> DeviceConfig? {
        devices[Self.key(uid, direction)]
    }

    /// Emoji and name as shown in the picker
    func title(for device: AudioDevice, _ direction: Direction) -> String {
        let config = config(uid: device.uid, direction)
        let name = config?.trimmedDisplayName ?? ""
        let emoji = config?.emoji ?? ""
        return "\(emoji.isEmpty ? direction.defaultEmoji : emoji) \(name.isEmpty ? device.name : name)"
    }

    func isHidden(_ device: AudioDevice, _ direction: Direction) -> Bool {
        config(uid: device.uid, direction)?.hidden ?? false
    }

    func update(uid: String, name: String, _ direction: Direction, _ change: (inout DeviceConfig) -> Void) {
        let key = Self.key(uid, direction)
        var config = devices[key] ?? DeviceConfig(name: name)
        config.name = name
        change(&config)
        // Drop entries that no longer customise anything so disconnected devices don't linger in settings
        devices[key] = config.isDefault ? nil : config
        saveDevices()
    }

    /// Back to the default emoji, name and visibility
    func reset(uid: String, _ direction: Direction) {
        devices[Self.key(uid, direction)] = nil
        saveDevices()
    }

    private func saveDevices() {
        defaults.set(try? JSONEncoder().encode(devices), forKey: "devices")
    }

    /// Every customised device for a direction, including ones that aren't currently connected
    func savedDevices(_ direction: Direction) -> [(uid: String, config: DeviceConfig)] {
        let prefix = "\(direction.rawValue):"
        return devices
            .compactMap { key, config in key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), config) : nil }
            .sorted { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
    }

    /// nil means the user cleared the shortcut; falls back to the default if it was never set
    var shortcut: Shortcut? {
        get {
            guard let data = defaults.data(forKey: "shortcut") else { return .default }
            // A cleared shortcut is stored as JSON null, which fails to decode as a Shortcut
            return try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }
}
