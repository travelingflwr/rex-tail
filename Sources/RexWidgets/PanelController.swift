import AppKit
import SwiftUI

/// The floating panel that docks to the right edge of Rex's window.
///
/// Showing the panel narrows Rex just enough to fit it on screen (remembering
/// how much); hiding it gives that width back. After that the panel follows
/// Rex and never fights the user: if Rex is later widened into the panel's
/// space, the panel overlaps Rex's right edge instead of shrinking it again.
final class PanelController {
    private let tracker: RexTracker
    private let model: PanelModel
    private let panel: NSPanel

    private let width: CGFloat = 300
    private let gap: CGFloat = 8
    private let minRexWidth: CGFloat = 480
    private let cornerRadius: CGFloat = 16

    private var timer: Timer?
    private var tick = 0
    private var lastActive = false
    /// The window we already made room for, so we only do it once per show.
    private var roomMadeFor: AXUIElement?
    /// How much we narrowed Rex, so hiding can give it back.
    private var shrink: (window: AXUIElement, amount: CGFloat, width: CGFloat)?
    /// The screen Rex was last on, so the desktop spot stays on the same display.
    private var lastScreen: NSScreen?

    // Drawer mode: when Rex is out of sight the panel tucks away behind a slim
    // handle on the screen's right edge and slides out while the pointer is on it.
    private let handle: NSPanel
    private let handleSize = NSSize(width: 14, height: 120)
    private var inDrawer = false
    private var drawerOpen = false
    private var animating = false
    private var pointerLeftAt: Date?

    private(set) var wantsVisible: Bool {
        didSet { UserDefaults.standard.set(wantsVisible, forKey: "panelVisible") }
    }

    init(tracker: RexTracker, model: PanelModel) {
        self.tracker = tracker
        self.model = model
        wantsVisible = UserDefaults.standard.object(forKey: "panelVisible") as? Bool ?? true
        panel = Self.makePanel(model: model, cornerRadius: cornerRadius)
        handle = Self.makeHandle()

        tracker.onChange = { [weak self] in self?.update() }
        // Rex reports moves as they happen, but polling quickly while a mouse
        // button is down keeps the panel glued on during a drag.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func toggle() {
        wantsVisible.toggle()
        if wantsVisible {
            roomMadeFor = nil
        } else {
            restoreRoom()
        }
        update()
    }

    private func poll() {
        tick += 1
        let dragging = NSEvent.pressedMouseButtons != 0 && tracker.isActive
        if dragging || tick % 30 == 0 { update() }
        if inDrawer { trackPointer() }
    }

    func update() {
        guard AXIsProcessTrusted() else { return hide("Waiting for Accessibility access") }
        guard wantsVisible else { return hide("Hidden — ⌃⌥⌘W to show") }
        // Dock beside Rex only while Rex is the app in front (or we are, e.g. showing an
        // upgrade prompt). Otherwise Rex is behind other apps and the panel would be
        // too, so it becomes the edge drawer instead.
        let rexInFront = tracker.isActive || NSApp.isActive
        guard rexInFront, tracker.isRunning, !tracker.isHidden, var state = tracker.windowState(),
              !state.isMinimized, tracker.isOnScreenInCurrentSpace() else { return enterDrawer() }
        lastScreen = screen(for: state.frame)
        leaveDrawer()

        if let window = tracker.window, roomMadeFor.map({ !CFEqual($0, window) }) ?? true {
            roomMadeFor = window
            if makeRoom(state, window: window), let updated = tracker.windowState() {
                state = updated
            }
        }

        let frame = panelFrame(for: state)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        let active = tracker.isActive
        // Bring the panel forward when Rex comes to the front, and keep it above
        // Rex whenever the two overlap (Rex widened into the panel, or full screen),
        // since clicking Rex raises Rex's window over it.
        let overlapsRex = frame.intersects(state.frame.insetBy(dx: 1, dy: 1))
        if !panel.isVisible || (active && (!lastActive || overlapsRex)) {
            panel.orderFrontRegardless()
        }
        lastActive = active
        setStatus(state.isFullScreen ? "Docked (full screen)" : "Docked to Rex")
    }

    // MARK: Drawer

    /// The screen edge the drawer lives on: the display Rex was last on.
    private var drawerScreen: NSRect? {
        (lastScreen.flatMap { s in NSScreen.screens.first { $0 == s } } ?? NSScreen.main)?.visibleFrame
    }

    private func openFrame(_ v: NSRect) -> NSRect {
        NSRect(x: v.maxX - width - gap, y: v.minY + gap, width: width, height: v.height - gap * 2)
    }

    /// Just past the screen edge, where the panel slides in from.
    private func closedFrame(_ v: NSRect) -> NSRect {
        openFrame(v).offsetBy(dx: width + gap * 2, dy: 0)
    }

    /// With Rex out of sight, collapse to a handle on the right edge of the screen.
    private func enterDrawer() {
        guard let v = drawerScreen else { return hide("No screen") }
        if !inDrawer {
            inDrawer = true
            drawerOpen = false
            pointerLeftAt = nil
            if panel.isVisible { panel.orderOut(nil) }
            panel.level = .floating
        }
        let handleFrame = NSRect(x: v.maxX - handleSize.width, y: v.midY - handleSize.height / 2,
                                 width: handleSize.width, height: handleSize.height)
        if handle.frame != handleFrame { handle.setFrame(handleFrame, display: true) }
        if !handle.isVisible { handle.orderFrontRegardless() }
        if drawerOpen, !animating, panel.frame != openFrame(v) { panel.setFrame(openFrame(v), display: true) }
        lastActive = false
        setStatus(!tracker.isRunning ? "Drawer — Rex isn't running"
                  : tracker.isActive ? "Drawer — Rex is out of sight" : "Drawer — Rex is in the background")
    }

    /// Back to docking beside Rex.
    private func leaveDrawer() {
        guard inDrawer else { return }
        inDrawer = false
        drawerOpen = false
        animating = false
        handle.orderOut(nil)
        panel.level = .normal
    }

    /// Opens while the pointer is on the handle or the open drawer; closes shortly after it leaves.
    private func trackPointer() {
        let mouse = NSEvent.mouseLocation
        let onHandle = handle.frame.insetBy(dx: -8, dy: -8).contains(mouse)
        let onPanel = drawerOpen && panel.frame.insetBy(dx: -12, dy: -12).contains(mouse)
        if onHandle || onPanel {
            pointerLeftAt = nil
            if !drawerOpen { slideDrawer(open: true) }
        } else if drawerOpen {
            let left = pointerLeftAt ?? Date()
            pointerLeftAt = left
            if Date().timeIntervalSince(left) > 0.4 { slideDrawer(open: false) }
        }
    }

    private func slideDrawer(open: Bool) {
        guard let v = drawerScreen else { return }
        drawerOpen = open
        pointerLeftAt = nil
        animating = true
        if open {
            panel.setFrame(closedFrame(v), display: false)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: open ? .easeOut : .easeIn)
            panel.animator().setFrame(open ? openFrame(v) : closedFrame(v), display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.animating = false
            // Out of sight once closed, so it can't peek onto a display to the right.
            if !self.drawerOpen, self.inDrawer { self.panel.orderOut(nil) }
            self.panel.invalidateShadow()
        })
    }

    private func hide(_ reason: String) {
        leaveDrawer()
        if panel.isVisible { panel.orderOut(nil) }
        lastActive = false
        setStatus(reason)
    }

    private func setStatus(_ s: String) {
        if model.status != s { model.status = s }
    }

    // MARK: Layout

    private func panelFrame(for state: RexWindowState) -> NSRect {
        let r = state.frame
        if state.isFullScreen {
            // Rex owns the whole screen; float over its right edge.
            return NSRect(x: r.maxX - width - gap, y: r.minY + gap, width: width, height: r.height - gap * 2)
        }
        let visible = screen(for: r)?.visibleFrame ?? r
        // Sit beside Rex, but never off screen (overlap Rex if there's no room).
        let x = min(r.maxX + gap, visible.maxX - width - gap)
        return NSRect(x: x, y: r.minY, width: width, height: r.height)
    }

    /// Narrows Rex so the panel fits beside it. Returns true if Rex was resized.
    private func makeRoom(_ state: RexWindowState, window: AXUIElement) -> Bool {
        guard !state.isFullScreen, let visible = screen(for: state.frame)?.visibleFrame else { return false }
        let needed = state.frame.maxX + gap + width + gap - visible.maxX
        guard needed > 0.5 else { return false }
        let newWidth = state.frame.width - needed
        guard newWidth >= minRexWidth, tracker.setWindowWidth(newWidth) else { return false }
        shrink = (window, needed, newWidth)
        return true
    }

    /// Gives back the width taken by makeRoom, unless the user resized Rex since.
    func restoreRoom() {
        guard let s = shrink else { return }
        shrink = nil
        guard let window = tracker.window, CFEqual(window, s.window),
              let state = tracker.windowState(), abs(state.frame.width - s.width) < 2 else { return }
        tracker.setWindowWidth(state.frame.width + s.amount)
    }

    private func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            area(a.frame.intersection(rect)) < area(b.frame.intersection(rect))
        }
    }

    private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    // MARK: Window

    private static func makePanel(model: PanelModel, cornerRadius: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // Present in every Space (and over full-screen Rex); update() hides it
        // wherever Rex isn't showing.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // The same translucent material macOS uses for sidebars.
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: cornerRadius)

        let host = NSHostingView(rootView: PanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }

    /// The slim pill on the screen edge that opens the drawer.
    private static func makeHandle() -> NSPanel {
        let handle = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 14, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        handle.isOpaque = false
        handle.backgroundColor = .clear
        handle.hasShadow = true
        handle.level = .floating
        handle.hidesOnDeactivate = false
        handle.isReleasedWhenClosed = false
        handle.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        handle.contentView = NSHostingView(rootView: DrawerHandle())
        return handle
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A tab on the screen edge, rounded on the side facing the screen, with a grip line.
private struct DrawerHandle: View {
    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7, style: .continuous)
        ZStack {
            shape.fill(.regularMaterial)
            shape.strokeBorder(.white.opacity(0.35), lineWidth: 1)
            Capsule().fill(.primary.opacity(0.55)).frame(width: 3, height: 40)
        }
        .environment(\.colorScheme, .dark)
    }
}
