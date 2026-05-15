import AppKit
import SwiftUI

@MainActor
final class PlacementWindow: NSPanel {
    private static var shared: PlacementWindow?
    private var coordinator: PlacementCoordinator?

    static func show(coordinator: PlacementCoordinator, on builtinDisplayID: CGDirectDisplayID) {
        if let existing = shared {
            existing.close()
            shared = nil
        }

        let window = PlacementWindow(coordinator: coordinator, builtinDisplayID: builtinDisplayID)
        shared = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func dismiss() {
        shared?.close()
        shared = nil
    }

    private init(coordinator: PlacementCoordinator, builtinDisplayID: CGDirectDisplayID) {
        self.coordinator = coordinator

        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 520)
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false

        // Host SwiftUI content
        let rootView = PlacementEditorView(coordinator: coordinator)
            .frame(width: 720, height: 520)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true
        self.contentView = hostingView

        // Center on built-in display
        centerOnDisplay(builtinDisplayID)
    }

    private func centerOnDisplay(_ displayID: CGDirectDisplayID) {
        let displayBounds = CGDisplayBounds(displayID)

        // Find the NSScreen that corresponds to this display
        if let screen = NSScreen.screens.first(where: {
            let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return screenNumber == displayID
        }) {
            let windowWidth: CGFloat = 720
            let windowHeight: CGFloat = 520
            let x = screen.frame.origin.x + (screen.frame.width - windowWidth) / 2
            let y = screen.frame.origin.y + (screen.frame.height - windowHeight) / 2
            self.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            // Fallback: use CG coordinates manually
            let screenX = displayBounds.origin.x + (displayBounds.width - 720) / 2
            let screenY = displayBounds.origin.y + (displayBounds.height - 520) / 2
            self.setFrameOrigin(NSPoint(x: screenX, y: screenY))
        }
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let coordinator = coordinator else { return }

        switch event.keyCode {
        case 53:  // Esc
            if case .previewing = coordinator.phase {
                coordinator.interceptCountdown()
            } else {
                coordinator.revertPhysicalPreview()
                PlacementWindow.dismiss()
            }
        case 36:  // Return/Enter
            if case .placed = coordinator.phase {
                coordinator.confirmPlacement()
            }
        default:
            if case .previewing = coordinator.phase {
                coordinator.interceptCountdown()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if case .previewing = coordinator?.phase {
            coordinator?.interceptCountdown()
        } else {
            super.mouseDown(with: event)
        }
    }
}
