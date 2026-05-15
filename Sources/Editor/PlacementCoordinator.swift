import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - CanvasDisplay

/// Represents a resolved display rectangle for rendering on the editor canvas.
struct CanvasDisplay: Identifiable, Equatable {
    let id: String  // "builtin" or display name
    let displayID: CGDirectDisplayID
    let name: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let isBuiltin: Bool
}

// MARK: - PendingDisplay

/// A display waiting to be placed (the original new one, or unchained from the arrangement).
struct PendingDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    let vendor: UInt32
    let model: UInt32
    let width: Int
    let height: Int
}

// MARK: - PlacementConfig

/// Working placement state describing how a new display is positioned relative to an anchor.
struct PlacementConfig: Equatable {
    var anchorName: String  // relative_to value ("builtin" or display name)
    var position: FlexibleDisplay.Position
    var align: FlexibleDisplay.Alignment
    var offset: Int
    var rotation: Int  // 0, 90, or 270
    var pendingId: String  // vendor-model identifier for config save
}

// MARK: - PlacementPhase

/// State machine for the placement editor flow.
enum PlacementPhase: Equatable {
    case idle
    case anchorSelected(String)
    case pickingDisplay(String, FlexibleDisplay.Position)  // anchorId, position
    case placed(PlacementConfig)
    case finetuning(PlacementConfig, displayId: String)  // editing a display in-place
    case previewing(PlacementConfig, secondsLeft: Int)
}

// MARK: - PlacementCoordinator

/// Coordinates the placement editor flow: anchor selection, positioning, preview, and commit.
@MainActor
final class PlacementCoordinator: ObservableObject {

    // MARK: Published State

    @Published var phase: PlacementPhase = .idle
    @Published var arrangement: [CanvasDisplay] = []
    @Published var pendingDisplays: [PendingDisplay] = []
    /// Working dock owner. "builtin" or a `CanvasDisplay.id`. Persisted via
    /// `commitAllConfigs()`.
    @Published var workingDockOwner: String = "builtin"

    /// Configs with unsaved changes, keyed by canvas display ID. This is the single source
    /// of truth for what gets written on save.
    private(set) var committedConfigs: [String: PlacementConfig] = [:]

    /// Called after config is committed (countdown completes). Allows DisplayManager to reload.
    var onCommit: (() -> Void)?

    // MARK: Private

    private var savedPositions: [(CGDirectDisplayID, Int32, Int32)] = []
    private var countdownCancellable: AnyCancellable?
    /// Displays that were unchained during this session (vendor, model pairs to remove from config on save).
    private var removedDisplays: [(vendor: UInt32, model: UInt32)] = []
    /// Initial dock owner captured at session start; used by `canFinalize`.
    private let initialDockOwner: String

    // MARK: Init

    /// Init for placing a new display (from unknown-display prompt).
    init(arrangement: [CanvasDisplay], newDisplay: DisplayEntry, width: Int, height: Int, dockOwner: String = "builtin")
    {
        self.arrangement = arrangement
        self.pendingDisplays = [
            PendingDisplay(
                id: "\(newDisplay.vendor)-\(newDisplay.model)",
                name: newDisplay.name,
                vendor: newDisplay.vendor,
                model: newDisplay.model,
                width: width,
                height: height
            )
        ]
        self.workingDockOwner = dockOwner
        self.initialDockOwner = dockOwner

        // Auto-select the topmost display as anchor
        if let topmost = arrangement.min(by: { $0.y < $1.y }) {
            self.phase = .anchorSelected(topmost.id)
        }
    }

    /// Init for editing the current arrangement (opened from menubar).
    init(arrangement: [CanvasDisplay], dockOwner: String = "builtin") {
        self.arrangement = arrangement
        self.pendingDisplays = []
        self.phase = .idle
        self.workingDockOwner = dockOwner
        self.initialDockOwner = dockOwner
    }

    // MARK: - Dock Owner

    /// Set the working dock owner. Persists on commit; reverts on cancel.
    func setDockOwner(_ id: String) {
        workingDockOwner = id
    }

    // MARK: - Computed Properties

    /// Whether unsaved changes exist and can be saved.
    var canFinalize: Bool {
        !committedConfigs.isEmpty
            || !removedDisplays.isEmpty
            || workingDockOwner != initialDockOwner
    }

    /// The currently active pending display (the one being placed).
    var activePending: PendingDisplay? {
        switch phase {
        case .placed(let config), .previewing(let config, _):
            return pendingDisplays.first(where: { $0.id == config.pendingId })
        default:
            return pendingDisplays.first
        }
    }

    /// Effective width accounting for rotation (90/270 swaps dimensions).
    var effectiveNewWidth: Int {
        guard let pending = activePending else { return 0 }
        let r: Int
        switch phase {
        case .placed(let config), .previewing(let config, _):
            r = config.rotation
        default:
            r = 0
        }
        return (r == 90 || r == 270) ? pending.height : pending.width
    }

    /// Effective height accounting for rotation (90/270 swaps dimensions).
    var effectiveNewHeight: Int {
        guard let pending = activePending else { return 0 }
        let r: Int
        switch phase {
        case .placed(let config), .previewing(let config, _):
            r = config.rotation
        default:
            r = 0
        }
        return (r == 90 || r == 270) ? pending.width : pending.height
    }

    /// Current offset from the active config, or 0.
    var currentOffset: Int {
        switch phase {
        case .placed(let config), .previewing(let config, _), .finetuning(let config, _):
            return config.offset
        default:
            return 0
        }
    }

    // MARK: - Phase Transitions

    /// Unified tap handler for display blocks. State machine:
    ///
    /// **With pending displays (placement flow):**
    /// - tap unselected → anchor selection (direction indicators appear)
    /// - tap already-selected anchor → enter fine-tune
    /// - tap while fine-tuning same display → exit fine-tune, back to anchor-selected
    /// - tap a different display (from any sub-state) → switch anchor to that display
    ///
    /// **No pending displays (pure editing):**
    /// - tap any non-builtin → enter fine-tune (switch directly if already fine-tuning another)
    func handleDisplayTap(_ displayId: String) {
        if !pendingDisplays.isEmpty {
            // Placement flow: tap cycles through anchor → fine-tune → anchor
            switch phase {
            case .finetuning(_, let editId) where editId == displayId:
                // Tapping the currently fine-tuned display → back to anchor-selected
                finishFinetuning()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    phase = .anchorSelected(displayId)
                }

            case .anchorSelected(let anchorId) where anchorId == displayId:
                // Tapping the already-selected anchor → enter fine-tune
                editDisplay(displayId)

            case .placed:
                // Tapping another display while one is placed → commit placement, go directly to target
                guard commitPlacedDisplay() != nil else { break }
                if pendingDisplays.isEmpty {
                    editDisplay(displayId)
                } else {
                    selectAnchor(displayId)
                }

            case .idle, .anchorSelected, .finetuning:
                // Tapping a different display → select as anchor
                if case .finetuning(let prevConfig, let prevId) = phase {
                    committedConfigs[prevId] = prevConfig
                }
                selectAnchor(displayId)

            default:
                break
            }
        } else {
            // No pending displays: tap always enters/switches fine-tune
            if case .finetuning(_, let editId) = phase, editId == displayId {
                // Already fine-tuning this one — no-op (can't exit, nothing else to do)
                return
            }
            editDisplay(displayId)
        }
    }

    /// User selects an anchor display from the canvas.
    func selectAnchor(_ anchorId: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            phase = .anchorSelected(anchorId)
        }
    }

    /// User picks a position (edge) relative to the anchor.
    func placeDisplay(position: FlexibleDisplay.Position) {
        guard case .anchorSelected(let anchorId) = phase else { return }

        if pendingDisplays.count == 1, let pending = pendingDisplays.first {
            let config = PlacementConfig(
                anchorName: anchorId,
                position: position,
                align: .center,
                offset: 0,
                rotation: 0,
                pendingId: pending.id
            )
            phase = .placed(config)
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                phase = .pickingDisplay(anchorId, position)
            }
        }
    }

    /// User picks a display from the picker.
    func selectPendingForPlacement(_ pendingId: String) {
        guard case .pickingDisplay(let anchorId, let position) = phase else { return }

        let config = PlacementConfig(
            anchorName: anchorId,
            position: position,
            align: .center,
            offset: 0,
            rotation: 0,
            pendingId: pendingId
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            phase = .placed(config)
        }
    }

    /// Update the alignment of the currently placed/finetuned display.
    func updateAlignment(_ align: FlexibleDisplay.Alignment) {
        switch phase {
        case .placed(var config):
            config.align = align
            phase = .placed(config)
        case .finetuning(var config, let displayId):
            config.align = align
            phase = .finetuning(config, displayId: displayId)
            updateDisplayPosition(config: config, displayId: displayId)
        default:
            break
        }
    }

    /// Update the offset of the currently placed/finetuned display.
    func updateOffset(_ offset: Int) {
        switch phase {
        case .placed(var config):
            config.offset = offset
            phase = .placed(config)
        case .finetuning(var config, let displayId):
            config.offset = offset
            phase = .finetuning(config, displayId: displayId)
            updateDisplayPosition(config: config, displayId: displayId)
        default:
            break
        }
    }

    /// Recompute and update a display's position in the arrangement after fine-tune changes.
    /// Cascades to any displays that use this one as their anchor.
    private func updateDisplayPosition(config: PlacementConfig, displayId: String) {
        guard let idx = arrangement.firstIndex(where: { $0.id == displayId }),
            let anchor = arrangement.first(where: { $0.id == config.anchorName })
        else { return }

        let display = arrangement[idx]
        let w = display.width
        let h = display.height
        let (px, py): (Int, Int)

        switch config.position {
        case .left:
            px = anchor.x - w
            py = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
        case .right:
            px = anchor.x + anchor.width
            py = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
        case .above:
            py = anchor.y - h
            px = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
        case .below:
            py = anchor.y + anchor.height
            px = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
        }

        arrangement[idx] = CanvasDisplay(
            id: display.id,
            displayID: display.displayID,
            name: display.name,
            x: px, y: py,
            width: w, height: h,
            isBuiltin: display.isBuiltin
        )

        committedConfigs[displayId] = config

        // Cascade: reposition any displays anchored to this one
        cascadeDependents(of: displayId)
    }

    /// Recursively reposition displays that depend on the given display as their anchor.
    private func cascadeDependents(of anchorId: String) {
        guard let anchor = arrangement.first(where: { $0.id == anchorId }) else { return }

        for idx in arrangement.indices {
            let dep = arrangement[idx]
            guard dep.id != anchorId, !dep.isBuiltin else { continue }

            // Find config for this dependent — either pre-populated or reconstruct now
            guard let depConfig = committedConfigs[dep.id],
                depConfig.anchorName == anchorId
            else { continue }

            let w = dep.width
            let h = dep.height
            let (px, py): (Int, Int)

            switch depConfig.position {
            case .left:
                px = anchor.x - w
                py = alignY(depConfig.align, offset: depConfig.offset, anchor: anchor, height: h)
            case .right:
                px = anchor.x + anchor.width
                py = alignY(depConfig.align, offset: depConfig.offset, anchor: anchor, height: h)
            case .above:
                py = anchor.y - h
                px = alignX(depConfig.align, offset: depConfig.offset, anchor: anchor, width: w)
            case .below:
                py = anchor.y + anchor.height
                px = alignX(depConfig.align, offset: depConfig.offset, anchor: anchor, width: w)
            }

            arrangement[idx] = CanvasDisplay(
                id: dep.id,
                displayID: dep.displayID,
                name: dep.name,
                x: px, y: py,
                width: w, height: h,
                isBuiltin: dep.isBuiltin
            )

            cascadeDependents(of: dep.id)
        }
    }

    /// Ensure all non-builtin displays have a reconstructed config (for cascading to work).
    private func ensureAllConfigsReconstructed() {
        for display in arrangement where !display.isBuiltin {
            if committedConfigs[display.id] == nil {
                if let config = reconstructConfig(for: display) {
                    committedConfigs[display.id] = config
                }
            }
        }
    }

    /// Unchain the currently placed display: return to direction picking.
    func unchainPlacement() {
        guard case .placed(let config) = phase else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            phase = .anchorSelected(config.anchorName)
        }
    }

    /// Unchain an existing display from the arrangement: remove it and add to pending.
    func unchainExistingDisplay(_ displayId: String) {
        guard let display = arrangement.first(where: { $0.id == displayId }),
            !display.isBuiltin
        else { return }

        let vendor = CGDisplayVendorNumber(display.displayID)
        let model = CGDisplayModelNumber(display.displayID)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            arrangement.removeAll { $0.id == displayId }
            committedConfigs.removeValue(forKey: displayId)
            removedDisplays.append((vendor: vendor, model: model))
            pendingDisplays.append(
                PendingDisplay(
                    id: "\(vendor)-\(model)",
                    name: display.name,
                    vendor: vendor,
                    model: model,
                    width: display.width,
                    height: display.height
                ))

            // Auto-select if only one display remains
            if arrangement.count == 1, let sole = arrangement.first {
                phase = .anchorSelected(sole.id)
            } else if let topmost = arrangement.min(by: { $0.y < $1.y }) {
                phase = .anchorSelected(topmost.id)
            } else {
                phase = .idle
            }
        }
    }

    /// Cycle rotation: 0 -> 90 -> 270 -> 0.
    func cycleRotation() {
        guard case .placed(var config) = phase else { return }
        switch config.rotation {
        case 0: config.rotation = 90
        case 90: config.rotation = 270
        default: config.rotation = 0
        }
        phase = .placed(config)
    }

    /// Enter fine-tune mode for a display.
    func editDisplay(_ displayId: String) {
        guard let display = arrangement.first(where: { $0.id == displayId }),
            !display.isBuiltin
        else { return }

        // If already fine-tuning another display, commit that config first
        if case .finetuning(let prevConfig, let prevId) = phase {
            committedConfigs[prevId] = prevConfig
        }

        // Pre-populate configs for ALL non-builtin displays so cascading works
        ensureAllConfigsReconstructed()

        guard let config = committedConfigs[displayId] else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            phase = .finetuning(config, displayId: displayId)
        }
    }

    /// Exit fine-tuning mode, storing the current config.
    func finishFinetuning() {
        guard case .finetuning(let config, let displayId) = phase else { return }
        committedConfigs[displayId] = config
    }

    /// Accept current placement: add to arrangement, continue with next pending.
    func confirmPlacement() {
        guard case .placed = phase else { return }
        _ = withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            commitPlacedDisplay()
        }
    }

    /// Commits the placed display to the arrangement without animation.
    /// Returns the canvas ID of the committed display, or nil on failure.
    @discardableResult
    private func commitPlacedDisplay() -> String? {
        guard case .placed(let config) = phase else { return nil }
        guard let pending = pendingDisplays.first(where: { $0.id == config.pendingId }) else { return nil }

        pendingDisplays.removeAll { $0.id == config.pendingId }

        guard let anchor = arrangement.first(where: { $0.id == config.anchorName }) else { return nil }
        let w = (config.rotation == 90 || config.rotation == 270) ? pending.height : pending.width
        let h = (config.rotation == 90 || config.rotation == 270) ? pending.width : pending.height
        let (px, py) = computeOrigin(config: config, pending: pending, anchor: anchor)

        let canvasId = pending.name
        let canvasDisplay = CanvasDisplay(
            id: canvasId,
            displayID: findDisplayID(vendor: pending.vendor, model: pending.model) ?? 0,
            name: pending.name,
            x: px, y: py,
            width: w, height: h,
            isBuiltin: false
        )

        arrangement.append(canvasDisplay)
        committedConfigs[canvasId] = config
        // If this display was previously unchained, it's no longer a removal
        removedDisplays.removeAll { $0.vendor == pending.vendor && $0.model == pending.model }

        if pendingDisplays.isEmpty {
            phase = .idle
        } else {
            phase = .anchorSelected(canvasId)
        }

        return canvasId
    }

    /// User intercepts the countdown — revert physical positions, return to idle for further editing.
    func interceptCountdown() {
        countdownCancellable?.cancel()
        countdownCancellable = nil
        guard case .previewing = phase else { return }
        revertPhysicalPreview()
        phase = .idle
    }

    /// User accepts the preview early — commit all immediately.
    func acceptPreview() {
        countdownCancellable?.cancel()
        countdownCancellable = nil
        guard case .previewing = phase else { return }
        commitAllConfigs()
    }

    /// Trigger preview + countdown for all changed displays.
    func finalizeArrangement() {
        guard canFinalize else { return }

        // If only removals (no position changes), commit directly without preview
        if committedConfigs.isEmpty {
            commitAllConfigs()
            return
        }

        guard let firstConfig = committedConfigs.values.first else { return }
        applyPhysicalPreview()
        phase = .previewing(firstConfig, secondsLeft: 20)
        startCountdown()
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

    // MARK: - Adjacent Pairs (for chain icons)

    struct AdjacentPair: Equatable {
        let displayA: String
        let displayB: String
        let edge: FlexibleDisplay.Position  // edge of A where B touches
    }

    /// Returns all adjacent display pairs. displayB is always farther from builtin (gets unchained).
    func adjacentPairs() -> [AdjacentPair] {
        let depths = computeDepths()
        var pairs: [AdjacentPair] = []
        var seen: Set<String> = []

        for a in arrangement {
            for b in arrangement where b.id != a.id && !b.isBuiltin {
                let canonical = [a.id, b.id].sorted().joined(separator: "-")
                guard !seen.contains(canonical) else { continue }

                var edge: FlexibleDisplay.Position?
                if touchesAbove(anchor: a, other: b) {
                    edge = .above
                } else if touchesBelow(anchor: a, other: b) {
                    edge = .below
                } else if touchesLeft(anchor: a, other: b) {
                    edge = .left
                } else if touchesRight(anchor: a, other: b) {
                    edge = .right
                }

                guard let foundEdge = edge else { continue }
                seen.insert(canonical)

                let depthA = depths[a.id] ?? 0
                let depthB = depths[b.id] ?? 0

                if depthB >= depthA {
                    pairs.append(AdjacentPair(displayA: a.id, displayB: b.id, edge: foundEdge))
                } else {
                    let flippedEdge: FlexibleDisplay.Position
                    switch foundEdge {
                    case .above: flippedEdge = .below
                    case .below: flippedEdge = .above
                    case .left: flippedEdge = .right
                    case .right: flippedEdge = .left
                    }
                    pairs.append(AdjacentPair(displayA: b.id, displayB: a.id, edge: flippedEdge))
                }
            }
        }

        return pairs
    }

    /// BFS from builtin to compute depth for each display.
    private func computeDepths() -> [String: Int] {
        var depths: [String: Int] = [:]
        guard let builtin = arrangement.first(where: { $0.isBuiltin }) else { return depths }

        var queue: [String] = [builtin.id]
        depths[builtin.id] = 0

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let currentDepth = depths[current]!
            guard let currentDisplay = arrangement.first(where: { $0.id == current }) else { continue }

            for neighbor in arrangement where neighbor.id != current && depths[neighbor.id] == nil {
                let adjacent =
                    touchesAbove(anchor: currentDisplay, other: neighbor)
                    || touchesBelow(anchor: currentDisplay, other: neighbor)
                    || touchesLeft(anchor: currentDisplay, other: neighbor)
                    || touchesRight(anchor: currentDisplay, other: neighbor)
                if adjacent {
                    depths[neighbor.id] = currentDepth + 1
                    queue.append(neighbor.id)
                }
            }
        }

        return depths
    }

    // MARK: - Config Reconstruction

    /// Reconstruct a PlacementConfig for an existing display based on its adjacency.
    private func reconstructConfig(for display: CanvasDisplay) -> PlacementConfig? {
        let depths = computeDepths()
        let displayDepth = depths[display.id] ?? 999

        for other in arrangement where other.id != display.id {
            let otherDepth = depths[other.id] ?? 999
            guard otherDepth < displayDepth else { continue }

            if touchesAbove(anchor: other, other: display) {
                let (align, offset) = inferHorizontalAlignment(display: display, anchor: other)
                return PlacementConfig(
                    anchorName: other.id, position: .above, align: align,
                    offset: offset, rotation: 0,
                    pendingId: "\(CGDisplayVendorNumber(display.displayID))-\(CGDisplayModelNumber(display.displayID))"
                )
            } else if touchesBelow(anchor: other, other: display) {
                let (align, offset) = inferHorizontalAlignment(display: display, anchor: other)
                return PlacementConfig(
                    anchorName: other.id, position: .below, align: align,
                    offset: offset, rotation: 0,
                    pendingId: "\(CGDisplayVendorNumber(display.displayID))-\(CGDisplayModelNumber(display.displayID))"
                )
            } else if touchesLeft(anchor: other, other: display) {
                let (align, offset) = inferVerticalAlignment(display: display, anchor: other)
                return PlacementConfig(
                    anchorName: other.id, position: .left, align: align,
                    offset: offset, rotation: 0,
                    pendingId: "\(CGDisplayVendorNumber(display.displayID))-\(CGDisplayModelNumber(display.displayID))"
                )
            } else if touchesRight(anchor: other, other: display) {
                let (align, offset) = inferVerticalAlignment(display: display, anchor: other)
                return PlacementConfig(
                    anchorName: other.id, position: .right, align: align,
                    offset: offset, rotation: 0,
                    pendingId: "\(CGDisplayVendorNumber(display.displayID))-\(CGDisplayModelNumber(display.displayID))"
                )
            }
        }

        return nil
    }

    private func inferHorizontalAlignment(display: CanvasDisplay, anchor: CanvasDisplay) -> (
        FlexibleDisplay.Alignment, Int
    ) {
        let centerX = anchor.x + (anchor.width - display.width) / 2
        let leftX = anchor.x
        let rightX = anchor.x + anchor.width - display.width

        if display.x == centerX { return (.center, 0) }
        if display.x == leftX { return (.left_edge, 0) }
        if display.x == rightX { return (.right_edge, 0) }

        let dCenter = abs(display.x - centerX)
        let dLeft = abs(display.x - leftX)
        let dRight = abs(display.x - rightX)

        if dCenter <= dLeft && dCenter <= dRight {
            return (.center, display.x - centerX)
        } else if dLeft <= dRight {
            return (.left_edge, display.x - leftX)
        } else {
            return (.right_edge, display.x - rightX)
        }
    }

    private func inferVerticalAlignment(display: CanvasDisplay, anchor: CanvasDisplay) -> (
        FlexibleDisplay.Alignment, Int
    ) {
        let centerY = anchor.y + (anchor.height - display.height) / 2
        let topY = anchor.y
        let bottomY = anchor.y + anchor.height - display.height

        if display.y == centerY { return (.center, 0) }
        if display.y == topY { return (.top, 0) }
        if display.y == bottomY { return (.bottom, 0) }

        let dCenter = abs(display.y - centerY)
        let dTop = abs(display.y - topY)
        let dBottom = abs(display.y - bottomY)

        if dCenter <= dTop && dCenter <= dBottom {
            return (.center, display.y - centerY)
        } else if dTop <= dBottom {
            return (.top, display.y - topY)
        } else {
            return (.bottom, display.y - bottomY)
        }
    }

    // MARK: - Edge Detection (1px tolerance)

    func touchesAbove(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
        let edgeY = anchor.y
        let otherBottom = other.y + other.height
        guard abs(otherBottom - edgeY) <= 1 else { return false }
        return horizontalOverlap(a: anchor, b: other)
    }

    func touchesBelow(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
        let edgeY = anchor.y + anchor.height
        let otherTop = other.y
        guard abs(otherTop - edgeY) <= 1 else { return false }
        return horizontalOverlap(a: anchor, b: other)
    }

    func touchesLeft(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
        let edgeX = anchor.x
        let otherRight = other.x + other.width
        guard abs(otherRight - edgeX) <= 1 else { return false }
        return verticalOverlap(a: anchor, b: other)
    }

    func touchesRight(anchor: CanvasDisplay, other: CanvasDisplay) -> Bool {
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
                guard case .previewing(let cfg, let secondsLeft) = self.phase else {
                    self.countdownCancellable?.cancel()
                    return
                }
                if secondsLeft <= 1 {
                    self.countdownCancellable?.cancel()
                    self.countdownCancellable = nil
                    self.commitAllConfigs()
                } else {
                    self.phase = .previewing(cfg, secondsLeft: secondsLeft - 1)
                }
            }
    }

    // MARK: - Physical Preview (CG Display Configuration)

    /// Saves current positions, then moves all displays to their computed origins,
    /// translated so the working dock owner lands at (0,0) — mirroring `DisplayManager.align()`.
    private func applyPhysicalPreview() {
        savedPositions = []
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        for i in 0..<Int(count) {
            let bounds = CGDisplayBounds(ids[i])
            savedPositions.append((ids[i], Int32(bounds.origin.x), Int32(bounds.origin.y)))
        }

        let (dx, dy): (Int, Int)
        if workingDockOwner != "builtin",
            let pivot = arrangement.first(where: { $0.id == workingDockOwner })
        {
            (dx, dy) = (pivot.x, pivot.y)
        } else {
            (dx, dy) = (0, 0)
        }

        var cgConfig: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cgConfig) == .success else { return }

        for display in arrangement where display.displayID != 0 {
            CGConfigureDisplayOrigin(
                cgConfig,
                display.displayID,
                Int32(display.x - dx),
                Int32(display.y - dy)
            )
        }

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

    private func computeOrigin(config: PlacementConfig, pending: PendingDisplay, anchor: CanvasDisplay) -> (Int, Int) {
        let w = (config.rotation == 90 || config.rotation == 270) ? pending.height : pending.width
        let h = (config.rotation == 90 || config.rotation == 270) ? pending.width : pending.height

        switch config.position {
        case .left:
            return (anchor.x - w, alignY(config.align, offset: config.offset, anchor: anchor, height: h))
        case .right:
            return (anchor.x + anchor.width, alignY(config.align, offset: config.offset, anchor: anchor, height: h))
        case .above:
            return (alignX(config.align, offset: config.offset, anchor: anchor, width: w), anchor.y - h)
        case .below:
            return (alignX(config.align, offset: config.offset, anchor: anchor, width: w), anchor.y + anchor.height)
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

    /// Saves all changed placements to config and dismisses.
    private func commitAllConfigs() {
        var cfg = Config.load()

        guard let arrIdx = cfg.arrangements.firstIndex(where: { $0.name == cfg.active }) else {
            PlacementWindow.dismiss()
            return
        }

        for (displayId, config) in committedConfigs {
            guard let display = arrangement.first(where: { $0.id == displayId }) else { continue }

            let vendor = CGDisplayVendorNumber(display.displayID)
            let model = CGDisplayModelNumber(display.displayID)
            let entry = DisplayEntry(name: display.name, vendor: vendor, model: model)

            // Remove from all lists first
            cfg.arrangements[arrIdx].stacked.removeAll { $0.vendor == entry.vendor && $0.model == entry.model }
            cfg.arrangements[arrIdx].flexible.removeAll { $0.vendor == entry.vendor && $0.model == entry.model }
            cfg.ignored.removeAll { $0.vendor == entry.vendor && $0.model == entry.model }

            // Displace any display that occupies the same slot
            cfg.arrangements[arrIdx].flexible.removeAll { flex in
                flex.relative_to == config.anchorName && flex.position == config.position
            }
            if config.position == .above && config.anchorName == "builtin" {
                cfg.arrangements[arrIdx].stacked.removeAll { _ in true }
            }

            // Stacked = above + builtin + center + offset 0
            let isStacked =
                config.position == .above
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
        }

        // Remove unchained displays from config
        for removed in removedDisplays {
            cfg.arrangements[arrIdx].stacked.removeAll { $0.vendor == removed.vendor && $0.model == removed.model }
            cfg.arrangements[arrIdx].flexible.removeAll { $0.vendor == removed.vendor && $0.model == removed.model }
        }

        // Persist working dock owner. Normalize: "builtin" stores as nil.
        cfg.arrangements[arrIdx].dock_owner =
            workingDockOwner == "builtin" ? nil : workingDockOwner

        cfg.save()
        phase = .idle
        onCommit?()
        PlacementWindow.dismiss()
    }

    // MARK: - Display ID Resolution

    private func findDisplayID(vendor: UInt32, model: UInt32) -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)

        for i in 0..<Int(count) {
            let id = ids[i]
            guard CGDisplayIsBuiltin(id) == 0 else { continue }
            let v = CGDisplayVendorNumber(id)
            let m = CGDisplayModelNumber(id)
            if v == vendor && m == model {
                return id
            }
        }
        return nil
    }

}
