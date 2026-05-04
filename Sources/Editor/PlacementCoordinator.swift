import Foundation
import Combine
import CoreGraphics
import AppKit
import SwiftUI

// MARK: - CanvasDisplay

/// Represents a resolved display rectangle for rendering on the editor canvas.
struct CanvasDisplay: Identifiable, Equatable {
    let id: String          // "builtin" or display name
    let displayID: CGDirectDisplayID
    let name: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let isBuiltin: Bool
}

// MARK: - PlacementConfig

/// Working placement state describing how a new display is positioned relative to an anchor.
struct PlacementConfig: Equatable {
    var anchorName: String              // relative_to value ("builtin" or display name)
    var position: FlexibleDisplay.Position
    var align: FlexibleDisplay.Alignment
    var offset: Int
    var rotation: Int                   // 0, 90, or 270
}

// MARK: - PlacementPhase

/// State machine for the placement editor flow.
enum PlacementPhase: Equatable {
    case idle
    case anchorSelected(String)
    case placed(PlacementConfig)
    case previewing(PlacementConfig, secondsLeft: Int)
}

// MARK: - PlacementCoordinator

/// Coordinates the placement editor flow: anchor selection, positioning, preview, and commit.
@MainActor
final class PlacementCoordinator: ObservableObject {

    // MARK: Published State

    @Published var phase: PlacementPhase = .idle
    @Published var arrangement: [CanvasDisplay] = []

    // MARK: New Display Info

    let newDisplay: DisplayEntry
    let newDisplayWidth: Int
    let newDisplayHeight: Int

    /// Called after config is committed (countdown completes). Allows DisplayManager to reload.
    var onCommit: (() -> Void)?

    // MARK: Private

    private var savedPositions: [(CGDirectDisplayID, Int32, Int32)] = []
    private var countdownCancellable: AnyCancellable?
    private var newDisplayID: CGDirectDisplayID?

    // MARK: Init

    init(arrangement: [CanvasDisplay], newDisplay: DisplayEntry, width: Int, height: Int) {
        self.arrangement = arrangement
        self.newDisplay = newDisplay
        self.newDisplayWidth = width
        self.newDisplayHeight = height

        // Auto-select the topmost display as anchor (topmost stacked, or MacBook if alone)
        if let topmost = arrangement.min(by: { $0.y < $1.y }) {
            self.phase = .anchorSelected(topmost.id)
        }
    }

    // MARK: - Computed Properties

    /// Effective width accounting for rotation (90/270 swaps dimensions).
    var effectiveNewWidth: Int {
        let r: Int
        switch phase {
        case .placed(let config), .previewing(let config, _):
            r = config.rotation
        default:
            r = 0
        }
        return (r == 90 || r == 270) ? newDisplayHeight : newDisplayWidth
    }

    /// Effective height accounting for rotation (90/270 swaps dimensions).
    var effectiveNewHeight: Int {
        let r: Int
        switch phase {
        case .placed(let config), .previewing(let config, _):
            r = config.rotation
        default:
            r = 0
        }
        return (r == 90 || r == 270) ? newDisplayWidth : newDisplayHeight
    }

    /// Current offset from the active config, or 0.
    var currentOffset: Int {
        switch phase {
        case .placed(let config):
            return config.offset
        case .previewing(let config, _):
            return config.offset
        default:
            return 0
        }
    }

    // MARK: - Phase Transitions

    /// Step 1: User selects an anchor display from the canvas.
    func selectAnchor(_ anchorId: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            phase = .anchorSelected(anchorId)
        }
    }

    /// Step 2: User picks a position (edge) relative to the anchor.
    func placeDisplay(position: FlexibleDisplay.Position) {
        guard case .anchorSelected(let anchorId) = phase else { return }

        let defaultAlign: FlexibleDisplay.Alignment
        switch position {
        case .above, .below:
            defaultAlign = .center
        case .left, .right:
            defaultAlign = .center
        }

        let config = PlacementConfig(
            anchorName: anchorId,
            position: position,
            align: defaultAlign,
            offset: 0,
            rotation: 0
        )
        phase = .placed(config)
    }

    /// Update the alignment of the currently placed display.
    func updateAlignment(_ align: FlexibleDisplay.Alignment) {
        guard case .placed(var config) = phase else { return }
        config.align = align
        phase = .placed(config)
    }

    /// Update the offset of the currently placed display.
    func updateOffset(_ offset: Int) {
        guard case .placed(var config) = phase else { return }
        config.offset = offset
        phase = .placed(config)
    }

    /// Cycle rotation: 0 -> 90 -> 270 -> 0.
    func cycleRotation() {
        guard case .placed(var config) = phase else { return }
        switch config.rotation {
        case 0:   config.rotation = 90
        case 90:  config.rotation = 270
        default:  config.rotation = 0
        }
        phase = .placed(config)
    }

    /// Start the physical preview countdown (moves display via CG API).
    func confirmPlacement() {
        guard case .placed(let config) = phase else { return }
        applyPhysicalPreview(config: config)
        phase = .previewing(config, secondsLeft: 20)
        startCountdown()
    }

    /// User intercepts the countdown — revert physical preview, return to placed state.
    func interceptCountdown() {
        countdownCancellable?.cancel()
        countdownCancellable = nil
        guard case .previewing(let config, _) = phase else { return }
        revertPhysicalPreview()
        phase = .placed(config)
    }

    /// User accepts the preview early — commit immediately without waiting for countdown.
    func acceptPreview() {
        countdownCancellable?.cancel()
        countdownCancellable = nil
        guard case .previewing(let config, _) = phase else { return }
        commitConfig(config)
    }

    // MARK: - Free Edges

    /// Returns position cases for which the given anchor has no adjacent display (1px tolerance).
    func freeEdges(for anchorId: String) -> [FlexibleDisplay.Position] {
        guard let anchor = arrangement.first(where: { $0.id == anchorId }) else {
            return []
        }

        var free: [FlexibleDisplay.Position] = []
        let others = arrangement.filter { $0.id != anchorId }

        if !others.contains(where: { touchesAbove(anchor: anchor, other: $0) }) {
            free.append(.above)
        }
        if !others.contains(where: { touchesBelow(anchor: anchor, other: $0) }) {
            free.append(.below)
        }
        if !others.contains(where: { touchesLeft(anchor: anchor, other: $0) }) {
            free.append(.left)
        }
        if !others.contains(where: { touchesRight(anchor: anchor, other: $0) }) {
            free.append(.right)
        }

        return free
    }

    // MARK: - Edge Detection (1px tolerance)

    private func touchesAbove(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
        let edgeY = anchor.y
        let otherBottom = other.y + other.height
        guard abs(otherBottom - edgeY) <= 1 else { return false }
        return horizontalOverlap(a: anchor, b: other)
    }

    private func touchesBelow(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
        let edgeY = anchor.y + anchor.height
        let otherTop = other.y
        guard abs(otherTop - edgeY) <= 1 else { return false }
        return horizontalOverlap(a: anchor, b: other)
    }

    private func touchesLeft(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
        let edgeX = anchor.x
        let otherRight = other.x + other.width
        guard abs(otherRight - edgeX) <= 1 else { return false }
        return verticalOverlap(a: anchor, b: other)
    }

    private func touchesRight(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
        let edgeX = anchor.x + anchor.width
        let otherLeft = other.x
        guard abs(otherLeft - edgeX) <= 1 else { return false }
        return verticalOverlap(a: anchor, b: other)
    }

    private func horizontalOverlap(a: CanvasDisplay, b: CanvasDisplay) -> Bool {
        let aLeft = a.x
        let aRight = a.x + a.width
        let bLeft = b.x
        let bRight = b.x + b.width
        return aLeft < bRight && bLeft < aRight
    }

    private func verticalOverlap(a: CanvasDisplay, b: CanvasDisplay) -> Bool {
        let aTop = a.y
        let aBottom = a.y + a.height
        let bTop = b.y
        let bBottom = b.y + b.height
        return aTop < bBottom && bTop < aBottom
    }

    // MARK: - Countdown Timer

    private func startCountdown() {
        countdownCancellable?.cancel()
        countdownCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard case .previewing(let config, let secondsLeft) = self.phase else {
                    self.countdownCancellable?.cancel()
                    return
                }
                if secondsLeft <= 1 {
                    // Time expired — commit config and dismiss
                    self.countdownCancellable?.cancel()
                    self.countdownCancellable = nil
                    self.commitConfig(config)
                } else {
                    self.phase = .previewing(config, secondsLeft: secondsLeft - 1)
                }
            }
    }

    // MARK: - Physical Preview (CG Display Configuration)

    /// Saves current positions, then moves the new display to the computed origin.
    private func applyPhysicalPreview(config: PlacementConfig) {
        // Find the new display's CGDirectDisplayID
        guard let displayID = findNewDisplayID() else { return }
        self.newDisplayID = displayID

        // Save all current display positions for revert
        savedPositions = []
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        for i in 0..<Int(count) {
            let bounds = CGDisplayBounds(ids[i])
            savedPositions.append((ids[i], Int32(bounds.origin.x), Int32(bounds.origin.y)))
        }

        // Compute target origin
        guard let anchor = arrangement.first(where: { $0.id == config.anchorName }) else { return }
        let (targetX, targetY) = computeOrigin(config: config, anchor: anchor)

        // Apply via CG API
        var cgConfig: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cgConfig) == .success else { return }
        CGConfigureDisplayOrigin(cgConfig, displayID, Int32(targetX), Int32(targetY))
        CGCompleteDisplayConfiguration(cgConfig, .forSession)
    }

    /// Restores saved positions for all displays.
    func revertPhysicalPreview() {
        guard !savedPositions.isEmpty else { return }

        var cgConfig: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cgConfig) == .success else { return }
        for (id, x, y) in savedPositions {
            CGConfigureDisplayOrigin(cgConfig, id, x, y)
        }
        CGCompleteDisplayConfiguration(cgConfig, .forSession)
        savedPositions = []
    }

    // MARK: - Origin Computation

    private func computeOrigin(config: PlacementConfig, anchor: CanvasDisplay) -> (Int, Int) {
        let w = (config.rotation == 90 || config.rotation == 270) ? newDisplayHeight : newDisplayWidth
        let h = (config.rotation == 90 || config.rotation == 270) ? newDisplayWidth : newDisplayHeight

        switch config.position {
        case .left:
            let x = anchor.x - w
            let y = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
            return (x, y)

        case .right:
            let x = anchor.x + anchor.width
            let y = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
            return (x, y)

        case .above:
            let y = anchor.y - h
            let x = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
            return (x, y)

        case .below:
            let y = anchor.y + anchor.height
            let x = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
            return (x, y)
        }
    }

    private func alignY(_ align: FlexibleDisplay.Alignment, offset: Int, anchor: CanvasDisplay, height h: Int) -> Int {
        switch align {
        case .top:
            return anchor.y + offset
        case .center:
            return anchor.y + (anchor.height - h) / 2 + offset
        case .bottom:
            return anchor.y + anchor.height - h + offset
        case .left_edge, .right_edge:
            return anchor.y + offset
        }
    }

    private func alignX(_ align: FlexibleDisplay.Alignment, offset: Int, anchor: CanvasDisplay, width w: Int) -> Int {
        switch align {
        case .left_edge:
            return anchor.x + offset
        case .center:
            return anchor.x + (anchor.width - w) / 2 + offset
        case .right_edge:
            return anchor.x + anchor.width - w + offset
        case .top, .bottom:
            return anchor.x + offset
        }
    }

    // MARK: - Config Commit

    /// Determines stacked vs flexible, updates the active arrangement, saves, and dismisses.
    private func commitConfig(_ config: PlacementConfig) {
        var cfg = Config.load()

        let entry = newDisplay

        // Find the active arrangement index
        guard let arrIdx = cfg.arrangements.firstIndex(where: { $0.name == cfg.active }) else {
            PlacementWindow.dismiss()
            return
        }

        // Remove the new display from all lists first (in case it was previously configured)
        cfg.arrangements[arrIdx].stacked.removeAll { $0.vendor == entry.vendor && $0.model == entry.model }
        cfg.arrangements[arrIdx].flexible.removeAll { $0.vendor == entry.vendor && $0.model == entry.model }
        cfg.ignored.removeAll { $0.vendor == entry.vendor && $0.model == entry.model }

        // Displace any display that occupies the same slot (same anchor + position)
        cfg.arrangements[arrIdx].flexible.removeAll { flex in
            flex.relative_to == config.anchorName && flex.position == config.position
        }
        // If placing above builtin, also displace stacked entries (they occupy above-builtin)
        if config.position == .above && config.anchorName == "builtin" {
            cfg.arrangements[arrIdx].stacked.removeAll { _ in true }
        }

        // Stacked = above + builtin + center + offset 0
        let isStacked = config.position == .above
            && config.anchorName == "builtin"
            && config.align == .center
            && config.offset == 0

        if isStacked {
            cfg.arrangements[arrIdx].stacked.append(entry)
        } else {
            let flex = FlexibleDisplay(
                name: entry.name,
                vendor: entry.vendor,
                model: entry.model,
                position: config.position,
                relative_to: config.anchorName,
                align: config.align,
                offset: config.offset == 0 ? nil : config.offset,
                rotation: config.rotation == 0 ? nil : config.rotation
            )
            cfg.arrangements[arrIdx].flexible.append(flex)
        }

        cfg.save()
        phase = .idle
        onCommit?()

        PlacementWindow.dismiss()
    }

    // MARK: - Display ID Resolution

    private func findNewDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)

        for i in 0..<Int(count) {
            let id = ids[i]
            guard CGDisplayIsBuiltin(id) == 0 else { continue }
            let v = CGDisplayVendorNumber(id)
            let m = CGDisplayModelNumber(id)
            if v == newDisplay.vendor && m == newDisplay.model {
                return id
            }
        }
        return nil
    }

}
