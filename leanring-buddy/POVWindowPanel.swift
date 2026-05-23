//
//  POVWindowPanel.swift
//  leanring-buddy
//
//  Floating, resizable NSPanel that hosts the SwiftUI POVWindowView via
//  NSHostingView. Pattern mirrors OverlayWindow.swift / MenuBarPanelManager
//  but with real window chrome (titled, closable, miniaturizable,
//  resizable) so the user can grab and reposition it like a normal
//  utility window.
//
//  Lifecycle is driven by CompanionManager — Show / Hide are toggled
//  from the menu bar panel's "Show Clicky's POV" switch. The panel is
//  retained across show/hide so dragging position survives toggling.
//

import AppKit
import SwiftUI

@MainActor
final class POVWindowPanel: NSObject, NSWindowDelegate {
    private let agentWebSocketClient: AgentWebSocketClient

    private var hostingPanel: NSPanel?

    /// Tracked separately from `hostingPanel?.isVisible` because we want
    /// to know "should it be on screen" rather than "is AppKit currently
    /// drawing it" (the two diverge during animations).
    private(set) var isShowing: Bool = false

    /// Callback fired when the user clicks the close (x) traffic-light.
    /// CompanionManager uses this to flip its `isPovWindowVisible` flag
    /// so the menu bar toggle reflects reality.
    var onUserClosedPanel: (() -> Void)?

    private let defaultPanelWidth: CGFloat = 400
    private let defaultPanelHeight: CGFloat = 280

    init(agentWebSocketClient: AgentWebSocketClient) {
        self.agentWebSocketClient = agentWebSocketClient
        super.init()
    }

    // MARK: - Public lifecycle

    func show() {
        if hostingPanel == nil {
            createPanel()
        }
        guard let panel = hostingPanel else { return }
        panel.orderFrontRegardless()
        // makeKey is intentionally NOT called — the POV window should not
        // steal focus from the user's active app while they're running
        // workflows. This matches the OverlayWindow pattern.
        isShowing = true
    }

    func hide() {
        hostingPanel?.orderOut(nil)
        isShowing = false
    }

    // MARK: - Panel construction

    private func createPanel() {
        let initialContentFrame = computeInitialFrameForCursorScreen(
            width: defaultPanelWidth,
            height: defaultPanelHeight
        )

        // .nonactivatingPanel keeps the user's underlying app in focus.
        // .resizable + .titled + .closable + .miniaturizable give the user
        // standard window chrome — important because this is a real
        // utility window the user will resize, not a glanceable HUD.
        // .utilityWindow gives the slimmer title bar / always-on-top
        // utility-style behavior NSPanel is designed for.
        let panel = NSPanel(
            contentRect: initialContentFrame,
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .nonactivatingPanel,
                .utilityWindow
            ],
            backing: .buffered,
            defer: false
        )

        panel.title = "Clicky's POV"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        panel.delegate = self

        let hostingView = NSHostingView(
            rootView: POVWindowView(agentWebSocketClient: agentWebSocketClient)
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: initialContentFrame.width,
            height: initialContentFrame.height
        )
        panel.contentView = hostingView

        hostingPanel = panel
    }

    // MARK: - NSWindowDelegate

    /// Called when the user clicks the traffic-light close button. Instead
    /// of letting AppKit release the panel we just hide it and notify the
    /// owner — so the next show() reuses the same instance and the user's
    /// last drag position is preserved.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hostingPanel?.orderOut(nil)
        isShowing = false
        onUserClosedPanel?()
        return false
    }

    // MARK: - Initial positioning

    /// Default placement: anchored to the bottom-right corner of whichever
    /// screen currently contains the cursor, with a comfortable margin so
    /// it doesn't touch the dock or screen edges.
    private func computeInitialFrameForCursorScreen(
        width: CGFloat,
        height: CGFloat
    ) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first(where: { screen in
            screen.frame.contains(mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let cursorScreen else {
            // Last-ditch fallback so we still hand back a valid rect even on
            // a headless test build with no screens attached.
            return NSRect(x: 100, y: 100, width: width, height: height)
        }

        let visibleFrame = cursorScreen.visibleFrame
        let margin: CGFloat = 24
        let originX = visibleFrame.maxX - width - margin
        let originY = visibleFrame.minY + margin
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}
