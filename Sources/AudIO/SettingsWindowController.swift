import Cocoa
import ServiceManagement

// Two sections: per-device rename/hide, and the global shortcut with open-at-login.
// Shown on first launch, from the picker's gear button, and when the app is opened again while running.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let recorder = ShortcutRecorder()

    /// Set when the shortcut couldn't be registered, to explain why it does nothing
    var shortcutUnavailable = false {
        didSet { shortcutWarning.isHidden = !shortcutUnavailable }
    }

    private struct DeviceRef {
        let uid: String
        let name: String
        let direction: Direction
    }

    private let prefs = Preferences.shared
    private var window: NSWindow!
    private let shortcutWarning = NSTextField(labelWithString: "Already in use by another app")
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open AudI/O at login", target: nil, action: nil)
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let quitButton = NSButton(title: "Quit AudI/O", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    private let deviceSections = NSStackView()
    private var fieldRefs: [NSTextField: DeviceRef] = [:]
    private var emojiRefs: [NSTextField: DeviceRef] = [:]
    private var checkboxRefs: [NSButton: DeviceRef] = [:]
    private var resetRefs: [NSButton: DeviceRef] = [:]
    private var resetButtons: [String: NSButton] = [:]
    /// Connected device UIDs the rows were last built from, so default-device changes don't rebuild (and steal focus)
    private var listedUIDs: [[String]] = []

    /// Width of each section's content; fits the device grid's name and field columns
    private static let contentWidth: CGFloat = 530

    override init() {
        super.init()
        setupWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(devicesDidChange),
                                               name: AudioHAL.didChangeNotification, object: nil)
    }

    func show() {
        rebuildDeviceSections()
        refreshForShortcut()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Don't start with the cursor in the first name field
        window.makeFirstResponder(nil)
    }

    private func setupWindow() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AudI/O Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        deviceSections.orientation = .vertical
        deviceSections.alignment = .leading
        deviceSections.spacing = 20

        let devicesGroup = makeGroup([
            paragraph("Choose the emoji and name each device has in the picker, or hide ones you don't use. "
                + "Click an emoji to pick another. The current device is always shown."),
            deviceSections,
        ])

        shortcutWarning.textColor = .systemRed
        shortcutWarning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutWarning.isHidden = true
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "Shortcut:"), recorder, shortcutWarning])
        shortcutRow.spacing = 8

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginToggled)

        styleAsHint(shortcutStatus)
        shortcutStatus.isSelectable = false
        shortcutStatus.preferredMaxLayoutWidth = Self.contentWidth - 120
        shortcutStatus.widthAnchor.constraint(equalToConstant: Self.contentWidth - 120).isActive = true
        let statusRow = NSStackView(views: [shortcutStatus, quitButton])
        statusRow.alignment = .centerY
        statusRow.spacing = 12

        let shortcutGroup = makeGroup([
            paragraph("AudI/O can open the picker with its own shortcut. The shortcut only works while "
                + "AudI/O is running, so it stays running in the background. Turn on “Open AudI/O at login” "
                + "to keep the shortcut working after a restart."),
            shortcutRow,
            hint("Click the shortcut to record a new one. Esc cancels, ⌫ removes it."),
            loginCheckbox,
            statusRow,
        ])

        let stack = NSStackView(views: [
            sectionTitle("Devices"), devicesGroup,
            sectionTitle("Keyboard shortcut"), shortcutGroup,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(24, after: devicesGroup)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        // The stack doesn't enforce its trailing inset when fitting, so pin the groups to it
        for group in [devicesGroup, shortcutGroup] {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
    }

    private func fitWindow() {
        let top = window.frame.maxY
        window.contentView!.layoutSubtreeIfNeeded()
        window.setContentSize(window.contentView!.fittingSize)
        if window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
    }

    @objc private func devicesDidChange() {
        if window.isVisible { rebuildDeviceSections() }
    }

    private func rebuildDeviceSections(force: Bool = false) {
        let connected = Direction.allCases.map { AudioHAL.devices($0) }
        let uids = connected.map { $0.map(\.uid) }
        if window.isVisible && uids == listedUIDs && !force { return }
        listedUIDs = uids

        fieldRefs = [:]
        emojiRefs = [:]
        checkboxRefs = [:]
        resetRefs = [:]
        resetButtons = [:]
        deviceSections.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (direction, devices) in zip(Direction.allCases, connected) {
            deviceSections.addArrangedSubview(makeSection(direction, connected: devices))
        }
        fitWindow()
    }

    private func makeSection(_ direction: Direction, connected: [AudioDevice]) -> NSView {
        let title = NSTextField(labelWithString: direction.isInput ? "INPUTS" : "OUTPUTS")
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [[columnHeader("Device"), columnHeader("Emoji"), columnHeader("Name in picker"), columnHeader("Hide"), NSGridCell.emptyContentView]])
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.yPlacement = .center

        // Connected devices first, then customised devices that are currently disconnected
        let connectedUIDs = Set(connected.map(\.uid))
        let refs = connected.map { DeviceRef(uid: $0.uid, name: $0.name, direction: direction) }
            + prefs.savedDevices(direction)
                .filter { !connectedUIDs.contains($0.uid) }
                .map { DeviceRef(uid: $0.uid, name: $0.config.name, direction: direction) }

        for ref in refs {
            let config = prefs.config(uid: ref.uid, direction)
            let isConnected = connectedUIDs.contains(ref.uid)

            let label = NSTextField(labelWithString: ref.name)
            label.textColor = isConnected ? .labelColor : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let deviceCell = isConnected ? label : disconnectedCell(label: label)

            let emoji = EmojiField(string: config?.emoji ?? "")
            emoji.placeholderString = direction.defaultEmoji
            emoji.alignment = .center
            emoji.delegate = self
            emoji.toolTip = "Click to pick an emoji"
            emoji.widthAnchor.constraint(equalToConstant: 44).isActive = true
            emojiRefs[emoji] = ref

            let field = NSTextField(string: config?.displayName ?? "")
            field.placeholderString = ref.name
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            fieldRefs[field] = ref

            let hide = NSButton(checkboxWithTitle: "", target: self, action: #selector(hideToggled(_:)))
            hide.state = config?.hidden == true ? .on : .off
            hide.toolTip = "Hide from the picker (the current device is always shown)"
            checkboxRefs[hide] = ref

            let reset = makeResetButton(ref, isConnected: isConnected)
            grid.addRow(with: [deviceCell, emoji, field, hide, reset])
            updateResetButton(ref)
        }
        if refs.isEmpty {
            grid.addRow(with: [hint("No devices")])
        }
        grid.column(at: 0).width = 180
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 3).xPlacement = .center
        grid.column(at: 4).width = 16

        let section = NSStackView(views: [title, grid])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if let ref = fieldRefs[field] {
            prefs.update(uid: ref.uid, name: ref.name, ref.direction) { $0.displayName = field.stringValue }
            updateResetButton(ref)
        } else if let ref = emojiRefs[field] {
            // Keep only the newest character, so picking an emoji replaces the old one
            if field.stringValue.count > 1, let last = field.stringValue.last {
                field.stringValue = String(last)
            }
            let emoji = field.stringValue.trimmingCharacters(in: .whitespaces)
            prefs.update(uid: ref.uid, name: ref.name, ref.direction) { $0.emoji = emoji }
            updateResetButton(ref)
        }
    }

    // Device name with "Not connected" underneath
    private func disconnectedCell(label: NSTextField) -> NSView {
        let cell = NSStackView(views: [label, hint("Not connected")])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        return cell
    }

    private func makeResetButton(_ ref: DeviceRef, isConnected: Bool) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise",
                                             accessibilityDescription: "Reset")!,
                              target: self, action: #selector(resetDevice(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = isConnected
            ? "Reset to the default emoji and name"
            : "Reset to the default emoji and name, and remove it from this list"
        resetRefs[button] = ref
        resetButtons[Self.rowKey(ref)] = button
        return button
    }

    /// Only customised devices have something to reset
    private func updateResetButton(_ ref: DeviceRef) {
        resetButtons[Self.rowKey(ref)]?.isHidden = prefs.config(uid: ref.uid, ref.direction) == nil
    }

    private static func rowKey(_ ref: DeviceRef) -> String {
        "\(ref.direction.rawValue):\(ref.uid)"
    }

    @objc private func resetDevice(_ sender: NSButton) {
        guard let ref = resetRefs[sender] else { return }
        prefs.reset(uid: ref.uid, ref.direction)
        rebuildDeviceSections(force: true)
    }

    @objc private func hideToggled(_ sender: NSButton) {
        guard let ref = checkboxRefs[sender] else { return }
        prefs.update(uid: ref.uid, name: ref.name, ref.direction) { $0.hidden = sender.state == .on }
        updateResetButton(ref)
    }

    @objc private func loginToggled() {
        let service = SMAppService.mainApp
        do {
            if loginCheckbox.state == .on {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshLoginCheckbox()
    }

    private func refreshLoginCheckbox() {
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// With a shortcut AudI/O stays running in the background (and can open at login);
    /// without one it's launched by another app, shows the picker and quits when closed.
    func refreshForShortcut() {
        let runsInBackground = prefs.shortcut != nil
        if !runsInBackground && SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
        refreshLoginCheckbox()
        loginCheckbox.isEnabled = runsInBackground
        loginCheckbox.toolTip = runsInBackground ? nil : "Only needed when AudI/O has its own shortcut"
        shortcutStatus.stringValue = runsInBackground
            ? "AudI/O is running in the background. Open it again to show these settings."
            : "No shortcut, so AudI/O only runs while its windows are open. To open the picker "
                + "from another app's shortcut, have it run: open -a AudIO"
        quitButton.isHidden = !runsInBackground
        fitWindow()
    }

    // Emoji fields get their own field editor with no caret or selection highlight, since they're
    // only edited through the emoji picker (the shared editor is left alone for the name fields)
    private lazy var emojiFieldEditor: NSTextView = {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.insertionPointColor = .clear
        editor.selectedTextAttributes = [:]
        return editor
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is EmojiField ? emojiFieldEditor : nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Picks up changes made in System Settings → Login Items
        refreshLoginCheckbox()
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stopRecording()
        DispatchQueue.main.async { NSApp.dismissIfNoWindowsVisible() }
    }

    private func columnHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        styleAsHint(label)
        return label
    }

    private func styleAsHint(_ label: NSTextField) {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func paragraph(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = false
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.contentWidth
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return label
    }

    // Rounded, lightly filled box like System Settings' grouped sections
    private func makeGroup(_ views: [NSView]) -> NSBox {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.03)
        box.contentViewMargins = .zero
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + 28),
        ])
        return box
    }
}

// Single-character field that selects its contents and opens the emoji picker when clicked
final class EmojiField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        currentEditor()?.selectAll(nil)
        NSApp.orderFrontCharacterPalette(nil)
    }
}
