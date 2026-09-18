import Cocoa
import CoreAudio

class DeviceRowView: NSView {
    static let fontSize: CGFloat = 15
    static let horizontalPadding: CGFloat = 10

    let isCurrent: Bool
    let isFocused: Bool
    var onClick: (() -> Void)?

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(title: String, isCurrent: Bool, isFocused: Bool) {
        self.isCurrent = isCurrent
        self.isFocused = isFocused
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: Self.fontSize, weight: isCurrent ? .semibold : .regular)
        // Like a selected menu item: white on the accent colour in the focused column
        label.textColor = isCurrent && isFocused ? .alternateSelectedControlTextColor
            : isFocused || isCurrent ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Reserve the bold width so the window doesn't resize as the current device changes
        let boldWidth = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.fontSize, weight: .semibold)]).width)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: boldWidth),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        if isCurrent {
            color = isFocused ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)
        } else if isHovered {
            color = NSColor.labelColor.withAlphaComponent(0.06)
        } else {
            return
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

class KeyHandlingWindow: NSWindow {
    var onRightArrow: (() -> Void)?
    var onLeftArrow: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 124: // Right Arrow
                onRightArrow?()
                return
            case 123: // Left Arrow
                onLeftArrow?()
                return
            case 126: // Up Arrow
                onUpArrow?()
                return
            case 125: // Down Arrow
                onDownArrow?()
                return
            case 36: // Return Key
                onReturn?()
                return
            case 53: // Escape
                onEscape?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

// The two-column output/input picker shown by the global shortcut
@MainActor
final class PickerWindowController: NSObject, NSWindowDelegate {
    var onOpenSettings: (() -> Void)?

    private let prefs = Preferences.shared
    private var window: KeyHandlingWindow!
    private var rows: [Direction: NSStackView] = [:]

    private var activeDirection: Direction = .output
    private var devices: [Direction: [AudioDevice]] = [:]
    private var current: [Direction: AudioDeviceID] = [:]

    override init() {
        super.init()
        setupWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(devicesDidChange),
                                               name: AudioHAL.didChangeNotification, object: nil)
    }

    func toggle() {
        window.isKeyWindow ? hide() : show()
    }

    func show() {
        activeDirection = .output
        reload()
        window.center()
        // The newer NSApp.activate() is cooperative and won't take focus from the frontmost app
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window.isVisible }

    func hide() {
        window.orderOut(nil)
        NSApp.dismissIfNoWindowsVisible()
    }

    @objc private func devicesDidChange() {
        if window.isVisible { reload() }
    }

    // Re-reads devices and resizes to fit every row, keeping the top edge in place
    private func reload() {
        for direction in Direction.allCases {
            let currentID = AudioHAL.defaultDevice(direction)
            current[direction] = currentID
            // The current device is never hidden
            devices[direction] = AudioHAL.devices(direction).filter { !prefs.isHidden($0, direction) || $0.id == currentID }
        }
        render()

        let top = window.frame.maxY
        window.contentView!.layoutSubtreeIfNeeded()
        window.setContentSize(window.contentView!.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    private func setupWindow() {
        window = KeyHandlingWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AudI/O"
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self

        rows[.output] = makeRowsStack()
        rows[.input] = makeRowsStack()

        let columns = NSStackView(views: [
            makeColumn(title: "Output", rows: rows[.output]!),
            makeColumn(title: "Input", rows: rows[.input]!),
        ])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 16
        columns.translatesAutoresizingMaskIntoConstraints = false

        let keyHints = NSTextField(labelWithString: "← → switch   ·   ↑ ↓ select   ·   ↩ done")
        keyHints.font = .systemFont(ofSize: 11)
        keyHints.textColor = .tertiaryLabelColor
        keyHints.translatesAutoresizingMaskIntoConstraints = false

        // Translucent material behind everything, title bar included, like Control Center
        let contentView = NSVisualEffectView()
        contentView.material = .popover
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        contentView.addSubview(columns)
        contentView.addSubview(keyHints)
        window.contentView = contentView

        let content = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            columns.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            columns.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            keyHints.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 16),
            keyHints.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            keyHints.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        addSettingsButton()

        window.onRightArrow = { [weak self] in
            self?.activeDirection = .input
            self?.render()
        }
        window.onLeftArrow = { [weak self] in
            self?.activeDirection = .output
            self?.render()
        }
        window.onUpArrow = { [weak self] in
            self?.moveSelection(by: -1)
        }
        window.onDownArrow = { [weak self] in
            self?.moveSelection(by: 1)
        }
        // Devices are already switched as the selection moves
        window.onReturn = { [weak self] in
            self?.hide()
        }
        window.onEscape = { [weak self] in
            self?.hide()
        }
    }

    // Gear button on the right of the title bar, centred on the traffic lights and inset
    // from the right edge by the same amount as the close button is from the left
    private func addSettingsButton() {
        let button = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                              target: self, action: #selector(openSettings))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Settings (⌘,)"
        button.translatesAutoresizingMaskIntoConstraints = false

        guard let close = window.standardWindowButton(.closeButton), let titlebar = close.superview else { return }
        titlebar.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -close.frame.minX),
        ])
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    private func makeRowsStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func makeColumn(title: String, rows: NSStackView) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor

        // Indent the header to line up with the row text
        let headerContainer = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: DeviceRowView.horizontalPadding),
            header.trailingAnchor.constraint(lessThanOrEqualTo: headerContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
        ])

        let column = NSStackView(views: [headerContainer, rows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        rows.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    // Rebuilds both columns' rows to reflect the current devices and focused column
    private func render() {
        for direction in Direction.allCases {
            let stack = rows[direction]!
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (idx, device) in (devices[direction] ?? []).enumerated() {
                let row = DeviceRowView(title: prefs.title(for: device, direction),
                                        isCurrent: device.id == current[direction],
                                        isFocused: activeDirection == direction)
                row.onClick = { [weak self] in self?.selectDevice(direction, index: idx) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let list = devices[activeDirection] ?? []
        guard !list.isEmpty else { return }

        let currentIdx = list.firstIndex(where: { $0.id == current[activeDirection] }) ?? (delta > 0 ? -1 : list.count)
        let newIdx = min(max(currentIdx + delta, 0), list.count - 1)
        guard newIdx != currentIdx else { return }
        selectDevice(activeDirection, index: newIdx)
    }

    // Switches the device immediately (arrow keys or clicks)
    private func selectDevice(_ direction: Direction, index: Int) {
        let device = devices[direction]![index]
        if device.id != current[direction] {
            current[direction] = device.id
            AudioHAL.setDefaultDevice(device.id, direction)
        }
        activeDirection = direction
        render()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // Dismiss when clicking away, like a popover
    func windowDidResignKey(_ notification: Notification) {
        guard window.isVisible else { return }
        hide()
    }
}
