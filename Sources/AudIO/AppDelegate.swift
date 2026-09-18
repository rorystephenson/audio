import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let hotKey = HotKey()
    private let picker = PickerWindowController()
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        AudioHAL.startObservingChanges()

        hotKey.onPress = { [weak self] in self?.picker.toggle() }
        picker.onOpenSettings = { [weak self] in self?.showSettings() }
        settings.recorder.shortcut = prefs.shortcut
        settings.recorder.onChange = { [weak self] shortcut in
            self?.prefs.shortcut = shortcut
            self?.registerShortcut()
            self?.settings.refreshForShortcut()
        }
        settings.recorder.onRecordingChange = { [weak self] recording in
            // Pause the global shortcut so pressing it gets recorded instead of opening the picker
            if recording { self?.hotKey.unregister() } else { self?.registerShortcut() }
        }
        registerShortcut()

        if !prefs.hasLaunchedBefore || settings.shortcutUnavailable {
            // Explain how things work on first launch, since in background mode nothing is visible
            prefs.hasLaunchedBefore = true
            showSettings()
        } else if prefs.shortcut == nil {
            // Launched by another app's shortcut
            picker.show()
        }
    }

    // Opening the app again while it's running: with no shortcut of its own this is another app's
    // shortcut, so it toggles the picker; otherwise it's a way back into settings
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if prefs.shortcut == nil {
            picker.toggle()
        } else {
            showSettings()
        }
        return false
    }

    @objc func showSettings() {
        settings.show()
    }

    private func registerShortcut() {
        settings.shortcutUnavailable = !hotKey.register(prefs.shortcut)
    }

    // Not visible (the app has no menu bar), but provides ⌘, ⌘Q ⌘W and the
    // Edit shortcuts that text fields need for copy/paste
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AudI/O", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}

extension NSApplication {
    /// Once none of our windows are showing, either stays running in the background for the
    /// shortcut (handing focus back to the previous app) or quits if there's no shortcut
    func dismissIfNoWindowsVisible() {
        guard !windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        if Preferences.shared.shortcut == nil {
            terminate(nil)
        } else {
            hide(nil)
        }
    }
}
