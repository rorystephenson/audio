import Carbon
import Cocoa

// Button that captures the next key combination as the new shortcut.
// Esc cancels, ⌫ clears the shortcut.
@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    var onChange: ((Shortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var monitor: Any?
    private var isRecording: Bool { monitor != nil }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        onRecordingChange?(true)
        updateTitle()
    }

    func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        onRecordingChange?(false)
        updateTitle()
    }

    @objc private func windowDidResignKey() {
        stopRecording()
    }

    private func handle(_ event: NSEvent) {
        let hasModifiers = !event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
        if Int(event.keyCode) == kVK_Escape && !hasModifiers {
            stopRecording()
        } else if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) && !hasModifiers {
            shortcut = nil
            onChange?(nil)
            stopRecording()
        } else if let recorded = Shortcut(event: event) {
            shortcut = recorded
            onChange?(recorded)
            stopRecording()
        } else {
            NSSound.beep()
        }
    }

    private func updateTitle() {
        title = isRecording ? "Type shortcut…" : (shortcut?.display ?? "Click to set")
    }
}
