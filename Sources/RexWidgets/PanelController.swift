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

    private(set) var wantsVisible: Bool {
        didSet { UserDefaults.standard.set(wantsVisible, forKey: "panelVisible") }
    }

    init(tracker: RexTracker, model: PanelModel) {
        self.tracker = tracker
        self.model = model
        wantsVisible = UserDefaults.standard.object(forKey: "panelVisible") as? Bool ?? true
        panel = Self.makePanel(model: model, cornerRadius: cornerRadius)

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
    }

    func update() {
        guard AXIsProcessTrusted() else { return hide("Waiting for Accessibility access") }
        guard tracker.isRunning else { return hide("Rex isn't running") }
        guard wantsVisible else { return hide("Hidden — ⌃⌥⌘W to show") }
        guard !tracker.isHidden, var state = tracker.windowState(), !state.isMinimized,
              tracker.isOnScreenInCurrentSpace() else { return hide("Rex window not visible") }

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

    private func hide(_ reason: String) {
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
