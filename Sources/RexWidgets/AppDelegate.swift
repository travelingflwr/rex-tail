import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = RexTracker()
    private let model = PanelModel()
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var trustTimer: Timer?

    private let toggleItem = NSMenuItem(title: "Hide Panel", action: #selector(togglePanel), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility),
                                        keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(tracker: tracker, model: model)
        setUpStatusItem()

        // ⌃⌥⌘W toggles the panel from anywhere.
        hotKey = HotKey(keyCode: kVK_ANSI_W, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.panel.toggle()
        }

        tracker.start()
        model.weather.start()
        model.agents.start()
        model.hosts.start()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.tracker.attach()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.restoreRoom()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()

        let menu = NSMenu()
        menu.delegate = self
        toggleItem.target = self
        accessItem.target = self
        loginItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(accessItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Rex's Tail", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// The logo's silhouette (Resources/menubar.svg, made by scripts/make_logo.py) as a
    /// template image, so macOS tints it to match the menu bar.
    private static func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubar", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Rex's Tail")
        }
        let height: CGFloat = 16
        image.size = NSSize(width: (height * image.size.width / image.size.height).rounded(), height: height)
        image.isTemplate = true
        image.accessibilityDescription = "Rex's Tail"
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = (panel.wantsVisible ? "Hide Panel" : "Show Panel") + "  ⌃⌥⌘W"
        accessItem.isHidden = AXIsProcessTrusted()
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on; loginItem.title = "Open at Login"
        case .requiresApproval: loginItem.state = .mixed; loginItem.title = "Open at Login (approve in Settings…)"
        default: loginItem.state = .off; loginItem.title = "Open at Login"
        }
    }

    /// Adds or removes Rex's Tail as a login item (System Settings > General > Login Items).
    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch {
            NSLog("Rex's Tail: Open at Login failed: \(error.localizedDescription)")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func togglePanel() { panel.toggle() }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
