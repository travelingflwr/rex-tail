import AppKit
import ApplicationServices

/// Where Rex's window is, in Cocoa screen coordinates (origin bottom-left).
struct RexWindowState: Equatable {
    var frame: CGRect
    var isFullScreen: Bool
    var isMinimized: Bool
}

/// Watches the Rex app from the outside using the macOS Accessibility API.
/// Nothing here modifies Rex; it only reads its window frame and, when asked,
/// resizes the window the same way a window manager would.
final class RexTracker {
    static let bundleID = "com.superlogical.rex"

    var onChange: (() -> Void)?

    private(set) var app: NSRunningApplication?
    private(set) var window: AXUIElement?
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var onScreenCache: (date: Date, value: Bool)?

    var isRunning: Bool { app.map { !$0.isTerminated } ?? false }
    var isActive: Bool { app?.isActive ?? false }
    var isHidden: Bool { app?.isHidden ?? true }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            nc.addObserver(self, selector: #selector(workspaceEvent(_:)), name: name, object: nil)
        }
        attach()
    }

    /// Re-attaches to Rex (call after Accessibility access is granted).
    func attach() {
        detach()
        guard let rex = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .first(where: { !$0.isTerminated }) else {
            onChange?()
            return
        }
        app = rex
        let element = AXUIElementCreateApplication(rex.processIdentifier)
        appElement = element

        var obs: AXObserver?
        if AXObserverCreate(rex.processIdentifier, axCallback, &obs) == .success, let obs {
            observer = obs
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                      kAXWindowCreatedNotification] {
                AXObserverAddNotification(obs, element, n as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        refreshWindow()
        onChange?()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        window = nil
        app = nil
    }

    @objc private func workspaceEvent(_ n: Notification) {
        let changed = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        if changed == Self.bundleID,
           n.name == NSWorkspace.didLaunchApplicationNotification || n.name == NSWorkspace.didTerminateApplicationNotification {
            attach()
            return
        }
        onScreenCache = nil
        refreshWindow()
        onChange?()
    }

    fileprivate func handle(_ notification: String) {
        if notification != kAXMovedNotification && notification != kAXResizedNotification {
            refreshWindow()
        }
        onScreenCache = nil
        onChange?()
    }

    /// Picks Rex's main window and moves the move/resize observers onto it.
    private func refreshWindow() {
        guard let appElement else { return }
        let candidate = element(appElement, kAXMainWindowAttribute)
            ?? element(appElement, kAXFocusedWindowAttribute)
            ?? ((copy(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first)
        if let current = window, let candidate, CFEqual(current, candidate) { return }
        if candidate == nil && window != nil && windowState() != nil { return } // keep a still-valid window

        if let observer, let old = window {
            for n in Self.windowNotifications { AXObserverRemoveNotification(observer, old, n as CFString) }
        }
        window = candidate
        if let observer, let candidate {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for n in Self.windowNotifications { AXObserverAddNotification(observer, candidate, n as CFString, refcon) }
        }
    }

    private static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification,
    ]

    func windowState() -> RexWindowState? {
        guard let window,
              let posValue = copy(window, kAXPositionAttribute), let sizeValue = copy(window, kAXSizeAttribute)
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // AX uses a top-left origin anchored to the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
        return RexWindowState(
            frame: frame,
            isFullScreen: (copy(window, "AXFullScreen") as? Bool) ?? false,
            isMinimized: (copy(window, kAXMinimizedAttribute) as? Bool) ?? false
        )
    }

    /// Changes the window's width, keeping its left edge where it is.
    @discardableResult
    func setWindowWidth(_ width: CGFloat) -> Bool {
        guard let window, let state = windowState() else { return false }
        var size = CGSize(width: width, height: state.frame.height)
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    /// True when a Rex window is visible in the current Space.
    func isOnScreenInCurrentSpace() -> Bool {
        if let cache = onScreenCache, Date().timeIntervalSince(cache.date) < 0.5 { return cache.value }
        guard let pid = app?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let value = list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0
        }
        onScreenCache = (Date(), value)
        return value
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}

private let axCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    Unmanaged<RexTracker>.fromOpaque(refcon).takeUnretainedValue().handle(notification as String)
}
