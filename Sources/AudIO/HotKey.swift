import Carbon
import Cocoa

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, ...), as RegisterEventHotKey expects
    var modifiers: UInt32
    /// Display name of the key, captured when recorded since it depends on the keyboard layout
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), key: "A")

    var display: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }
}

extension Shortcut {
    /// nil unless ⌃, ⌥ or ⌘ is held, since a global shortcut without one would swallow normal typing
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.control, .option, .command]) else { return nil }

        let carbonFlags: [(NSEvent.ModifierFlags, Int)] = [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonFlags.filter { flags.contains($0.0) }.reduce(0) { $0 | UInt32($1.1) },
            key: Self.keyName(for: event)
        )
    }

    private static let specialKeys: [Int: String] = {
        var keys = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fKeys.enumerated() { keys[code] = "F\(i + 1)" }
        return keys
    }()

    private static func keyName(for event: NSEvent) -> String {
        if let name = specialKeys[Int(event.keyCode)] { return name }
        let chars = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars
    }
}

// System-wide shortcut via Carbon's RegisterEventHotKey, which (unlike an NSEvent global monitor)
// needs no Accessibility permission and swallows the key press
@MainActor
final class HotKey {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon events are delivered on the main thread
            MainActor.assumeIsolated { hotKey.onPress?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Returns false if the shortcut couldn't be registered, e.g. another app already owns it
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        let id = EventHotKeyID(signature: OSType(0x4155_4449), id: 1) // 'AUDI'
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }
}
