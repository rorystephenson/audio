import Cocoa

@main
enum AudIO {
    @MainActor
    static func main() {
        // Used by scripts/build.sh to generate the app icon
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render-iconset"), flag + 1 < args.count {
            do {
                try AppIcon.writeIconset(to: URL(fileURLWithPath: args[flag + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed to render icon: \(error)\n".utf8))
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Background app: no Dock icon or menu bar, but its windows can still take focus.
        // Info.plist sets LSUIElement too, this covers running the bare binary with `swift run`.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
