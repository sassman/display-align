import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

/// Resolved rectangle for a display during layout computation.
struct ResolvedDisplay {
    let name: String
    let displayID: CGDirectDisplayID
    var x: Int
    var y: Int
    let width: Int
    let height: Int
}

/// A pure, value-type view of a `CGDisplayMode` used by the mode matcher so
/// the selection logic can be unit-tested without real hardware.
struct DisplayModeCandidate: Equatable {
    let width: Int  // point ("looks like") size
    let height: Int
    let pixelWidth: Int  // native pixels
    let pixelHeight: Int
    let refreshHz: Double
}

/// Refresh rates are floating point and reported with minor jitter (and are
/// 0 for some panels), so compare with a small tolerance.
private func refreshMatches(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 0.5
}

/// Pure best-match selector. Returns the index of the best candidate for
/// `target`, or `nil` when there are no candidates (no acceptable match).
///
/// Priority:
///   1. Exact match on pixel size + point size + refresh.
///   2. Same pixel size + point size, ignoring refresh.
///   3. Nearest by (pixel-size distance, then point-size distance, then
///      refresh distance).
func bestMatchModeIndex(for target: DisplayResolution, among modes: [DisplayModeCandidate]) -> Int? {
    guard !modes.isEmpty else { return nil }

    // 1. Exact match (all five fields).
    if let i = modes.firstIndex(where: {
        $0.pixelWidth == target.pixelWidth && $0.pixelHeight == target.pixelHeight
            && $0.width == target.width && $0.height == target.height
            && refreshMatches($0.refreshHz, target.refreshHz)
    }) {
        return i
    }

    // 2. Same pixel + point size, ignoring refresh.
    if let i = modes.firstIndex(where: {
        $0.pixelWidth == target.pixelWidth && $0.pixelHeight == target.pixelHeight
            && $0.width == target.width && $0.height == target.height
    }) {
        return i
    }

    // 3. Nearest by lexicographic (pixel, point, refresh) distance.
    func score(_ m: DisplayModeCandidate) -> (Int, Int, Double) {
        let pixel = abs(m.pixelWidth - target.pixelWidth) + abs(m.pixelHeight - target.pixelHeight)
        let point = abs(m.width - target.width) + abs(m.height - target.height)
        let refresh = abs(m.refreshHz - target.refreshHz)
        return (pixel, point, refresh)
    }

    var bestIdx = 0
    var bestScore = score(modes[0])
    for i in 1..<modes.count {
        let s = score(modes[i])
        if s < bestScore {
            bestScore = s
            bestIdx = i
        }
    }

    // Safety ceiling on the nearest fallback: only accept a candidate that is
    // reasonably close to the target. Beyond the threshold we return nil so
    // the caller LEAVES THE DISPLAY ALONE rather than forcing a wildly
    // different mode (non-destructive). Exact and refresh-agnostic matches
    // returned above, so this gates only the approximate case. The best
    // candidate must land within 15% of the target on BOTH the summed
    // pixel-size delta and the summed point-size delta, each measured against
    // the target's own dimensions.
    let pixelBudget = Int(0.15 * Double(target.pixelWidth + target.pixelHeight))
    let pointBudget = Int(0.15 * Double(target.width + target.height))
    let (bestPixel, bestPoint, _) = bestScore
    guard bestPixel <= pixelBudget, bestPoint <= pointBudget else { return nil }

    return bestIdx
}

/// All currently active displays (built-in + externals). File-scope so both
/// `DisplayManager` and `PlacementCoordinator` snapshot the same display set.
func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
    return Array(ids.prefix(Int(count)))
}

/// Read the current display mode of `displayID` as a `DisplayResolution`,
/// or `nil` if the mode can't be read. File-scope so capture is defined once
/// and reused by both `DisplayManager` and `PlacementCoordinator`.
func currentResolution(for displayID: CGDirectDisplayID) -> DisplayResolution? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    return DisplayResolution(
        vendor: CGDisplayVendorNumber(displayID),
        model: CGDisplayModelNumber(displayID),
        width: mode.width,
        height: mode.height,
        pixelWidth: mode.pixelWidth,
        pixelHeight: mode.pixelHeight,
        refreshHz: mode.refreshRate
    )
}

final class DisplayManager: ObservableObject {
    @Published var externalName: String?
    @Published var isAligned = false
    @Published var autoAlign = true
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var statusMessage = "Starting..."

    /// Mirrors `config.arrangements.map(\.name)`. Republished after switches
    /// so the menu picker stays in sync.
    @Published private(set) var arrangementNames: [String] = []
    /// Mirrors `config.active`. Driven by `switchArrangement(_:)`.
    @Published private(set) var activeArrangement: String = ""
    /// Effective dock owner name for the active arrangement. "builtin" if unset.
    @Published private(set) var dockOwner: String = "builtin"
    /// "builtin" + all displays in the active arrangement, in stacked-then-flexible order.
    @Published private(set) var dockOwnerCandidates: [String] = ["builtin"]

    private var config: Config
    private var pendingPrompt = false

    init() {
        config = Config.load()
        publishArrangementState()
        startWatching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
            if let self = self, self.autoAlign, self.hasConfiguredExternals() {
                self.align()
            }
        }
    }

    private func publishArrangementState() {
        arrangementNames = config.arrangements.map(\.name)
        activeArrangement = config.active
        dockOwner = config.current.effectiveDockOwner
        dockOwnerCandidates =
            ["builtin"]
            + config.current.stacked.map(\.name)
            + config.current.flexible.map(\.name)
    }

    /// Switch the active arrangement and re-evaluate connected displays.
    /// If `autoAlign` is on and the new arrangement covers any connected
    /// external, immediately re-align so the windows actually move.
    func switchArrangement(_ name: String) {
        guard config.switchTo(name) else { return }
        publishArrangementState()
        refresh()
        if autoAlign, hasConfiguredExternals() {
            align()
        }
    }

    /// Set the dock owner for the active arrangement. Pass `nil` (or `"builtin"`)
    /// to revert to the built-in screen. Persists, republishes state, refreshes,
    /// and re-aligns if `autoAlign` is on.
    func setDockOwner(_ name: String?) {
        guard let idx = config.arrangements.firstIndex(where: { $0.name == config.active })
        else { return }
        // Normalize: "builtin" and nil are equivalent; we persist as nil.
        let resolved: String? = (name == nil || name == "builtin") ? nil : name
        guard config.arrangements[idx].dock_owner != resolved else { return }
        config.arrangements[idx].dock_owner = resolved
        config.save()
        publishArrangementState()
        refresh()
        if autoAlign { align() }
    }

    // MARK: - Display Mode Access

    /// All available modes for a display, including HiDPI/scaled variants.
    private func availableModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    /// Whether `mode` already matches the display's current mode (size +
    /// refresh), so `align()` can skip a no-op mode set and its screen flash.
    private func isCurrentMode(_ mode: CGDisplayMode, for displayID: CGDirectDisplayID) -> Bool {
        guard let cur = CGDisplayCopyDisplayMode(displayID) else { return false }
        return cur.width == mode.width && cur.height == mode.height
            && cur.pixelWidth == mode.pixelWidth && cur.pixelHeight == mode.pixelHeight
            && refreshMatches(cur.refreshRate, mode.refreshRate)
    }

    /// Find the best-matching `CGDisplayMode` for a stored resolution among a
    /// display's available modes, delegating selection to the pure matcher.
    func bestMatchMode(for target: DisplayResolution, among modes: [CGDisplayMode]) -> CGDisplayMode? {
        let candidates = modes.map {
            DisplayModeCandidate(
                width: $0.width,
                height: $0.height,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                refreshHz: $0.refreshRate
            )
        }
        guard let idx = bestMatchModeIndex(for: target, among: candidates) else { return nil }
        return modes[idx]
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText =
                enabled
                ? "Could not enable Start at Login"
                : "Could not disable Start at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Display Enumeration

    // `activeDisplays()` lives at file scope (see top of file) so the editor's
    // PlacementCoordinator shares the same enumeration.

    // MARK: - Display Identification

    func identifyDisplay(_ displayID: CGDirectDisplayID) -> String {
        let id = DisplayID(vendor: CGDisplayVendorNumber(displayID), model: CGDisplayModelNumber(displayID))

        // Check all config lists
        if let entry = config.current.stacked.first(where: { $0.displayID == id }) {
            return entry.name
        }
        if let entry = config.ignored.first(where: { $0.displayID == id }) {
            return entry.name
        }
        if let entry = config.current.flexible.first(where: { $0.displayID == id }) {
            return entry.name
        }

        // Fallback: "<Vendor> <NSScreen.localizedName>", e.g. "AOC U2790B".
        return Vendor.humanLabel(for: displayID)
    }

    /// Check if any connected external is configured (stacked or flexible).
    func hasConfiguredExternals() -> Bool {
        let displays = activeDisplays()
        return displays.contains { id in
            guard CGDisplayIsBuiltin(id) == 0 else { return false }
            let v = CGDisplayVendorNumber(id)
            let m = CGDisplayModelNumber(id)
            return config.isStacked(vendor: v, model: m) || config.isFlexible(vendor: v, model: m)
        }
    }

    // MARK: - Refresh

    func refresh() {
        let displays = activeDisplays()
        guard displays.contains(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            externalName = nil
            isAligned = false
            statusMessage = "No built-in display (clamshell?)"
            return
        }

        let externals = displays.filter { CGDisplayIsBuiltin($0) == 0 }
        guard !externals.isEmpty else {
            externalName = nil
            isAligned = false
            statusMessage = "No external display"
            return
        }

        // Show the first external's name (could show count if multiple)
        let names = externals.map { identifyDisplay($0) }
        externalName = names.joined(separator: ", ")

        // Check for unknown displays
        for ext in externals {
            let v = CGDisplayVendorNumber(ext)
            let m = CGDisplayModelNumber(ext)
            if !config.isKnown(vendor: v, model: m) {
                isAligned = false
                statusMessage = "Unknown display detected"
                if !pendingPrompt {
                    let name = identifyDisplay(ext)
                    promptUser(name: name, vendor: v, model: m)
                }
                return
            }
        }

        // All known — check alignment
        checkAlignment()
    }

    private func checkAlignment() {
        guard let resolved = computeLayout() else {
            statusMessage = "Layout computation failed"
            isAligned = false
            return
        }
        let layout = translateForDockOwner(resolved, owner: config.current.dock_owner)

        // Compare computed layout against actual positions. Builtin is included
        // — when it's not the dock owner, its target position is non-zero and
        // must match what's actually on screen.
        var allAligned = true
        for d in layout {
            let actual = CGDisplayBounds(d.displayID)
            if Int(actual.origin.x) != d.x || Int(actual.origin.y) != d.y {
                allAligned = false
                break
            }
        }

        isAligned = allAligned
        statusMessage = allAligned ? "Aligned" : "Not aligned"
    }

    // MARK: - Layout Computation

    /// Compute target positions for all displays based on config.
    /// Returns nil if layout cannot be resolved (missing reference display, etc.)
    private func computeLayout() -> [ResolvedDisplay]? {
        let displays = activeDisplays()
        guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        let builtinBounds = CGDisplayBounds(builtinID)
        var resolved: [ResolvedDisplay] = [
            ResolvedDisplay(
                name: "builtin",
                displayID: builtinID,
                x: 0, y: 0,
                width: Int(builtinBounds.width),
                height: Int(builtinBounds.height)
            )
        ]

        // Resolve stacked displays: centered above builtin
        for entry in config.current.stacked {
            guard
                let id = displays.first(where: {
                    CGDisplayIsBuiltin($0) == 0
                        && DisplayID(vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0))
                            == entry.displayID
                })
            else { continue }

            let bounds = CGDisplayBounds(id)
            let w = Int(bounds.width)
            let h = Int(bounds.height)
            let x = (Int(builtinBounds.width) - w) / 2
            let y = -h

            resolved.append(ResolvedDisplay(name: entry.name, displayID: id, x: x, y: y, width: w, height: h))
        }

        // Resolve flexible displays in dependency order
        var pending = config.current.flexible.filter { flex in
            displays.contains(where: {
                CGDisplayIsBuiltin($0) == 0
                    && DisplayID(vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0))
                        == flex.displayID
            })
        }

        var maxIterations = pending.count + 1
        while !pending.isEmpty && maxIterations > 0 {
            maxIterations -= 1
            var nextPending: [FlexibleDisplay] = []

            for flex in pending {
                // Find the reference display in already-resolved list
                let refName = flex.relative_to == "builtin" ? "builtin" : flex.relative_to
                guard let ref = resolved.first(where: { $0.name == refName }) else {
                    nextPending.append(flex)
                    continue
                }

                guard
                    let id = displays.first(where: {
                        CGDisplayIsBuiltin($0) == 0
                            && DisplayID(vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0))
                                == flex.displayID
                    })
                else { continue }

                let bounds = CGDisplayBounds(id)
                let w = Int(bounds.width)
                let h = Int(bounds.height)
                let (x, y) = computeOrigin(flex: flex, ref: ref, width: w, height: h)

                resolved.append(ResolvedDisplay(name: flex.name, displayID: id, x: x, y: y, width: w, height: h))
            }

            pending = nextPending
        }

        return resolved
    }

    /// Compute the (x, y) origin for a flexible display relative to a reference.
    private func computeOrigin(flex: FlexibleDisplay, ref: ResolvedDisplay, width w: Int, height h: Int) -> (Int, Int) {
        let offset = flex.effectiveOffset

        switch flex.position {
        case .left:
            let x = ref.x - w
            let y = alignY(flex.align, offset: offset, ref: ref, height: h)
            return (x, y)

        case .right:
            let x = ref.x + ref.width
            let y = alignY(flex.align, offset: offset, ref: ref, height: h)
            return (x, y)

        case .above:
            let y = ref.y - h
            let x = alignX(flex.align, offset: offset, ref: ref, width: w)
            return (x, y)

        case .below:
            let y = ref.y + ref.height
            let x = alignX(flex.align, offset: offset, ref: ref, width: w)
            return (x, y)
        }
    }

    /// Compute Y origin for left/right positioning.
    private func alignY(_ align: FlexibleDisplay.Alignment, offset: Int, ref: ResolvedDisplay, height h: Int) -> Int {
        switch align {
        case .top:
            return ref.y + offset
        case .center:
            return ref.y + (ref.height - h) / 2 + offset
        case .bottom:
            return ref.y + ref.height - h + offset
        case .left_edge, .right_edge:
            // Shouldn't be used for left/right, treat as top
            return ref.y + offset
        }
    }

    /// Compute X origin for above/below positioning.
    private func alignX(_ align: FlexibleDisplay.Alignment, offset: Int, ref: ResolvedDisplay, width w: Int) -> Int {
        switch align {
        case .left_edge:
            return ref.x + offset
        case .center:
            return ref.x + (ref.width - w) / 2 + offset
        case .right_edge:
            return ref.x + ref.width - w + offset
        case .top, .bottom:
            // Shouldn't be used for above/below, treat as left
            return ref.x + offset
        }
    }

    // MARK: - Dock Owner Translation

    /// Translate a resolved layout so the named owner lands at (0,0).
    /// Returns the layout unchanged when:
    ///   - `owner` is nil or "builtin" (default case)
    ///   - `owner` names a display that isn't in `layout` (silent builtin fallback)
    private func translateForDockOwner(
        _ layout: [ResolvedDisplay],
        owner: String?
    ) -> [ResolvedDisplay] {
        let target = owner ?? "builtin"
        guard target != "builtin",
            let pivot = layout.first(where: { $0.name == target })
        else { return layout }

        let dx = pivot.x
        let dy = pivot.y
        return layout.map { d in
            var copy = d
            copy.x -= dx
            copy.y -= dy
            return copy
        }
    }

    // MARK: - Align

    func align() {
        guard let resolved = computeLayout() else {
            statusMessage = "Cannot compute layout"
            return
        }

        // Bail only if there are no externals at all (no point aligning a solo
        // builtin). Translation shifts positions but never changes which
        // displays are built-in, so this check is valid pre-translation.
        let hasExternal = resolved.contains { CGDisplayIsBuiltin($0.displayID) == 0 }
        guard hasExternal else {
            statusMessage = "No displays to move"
            return
        }

        // Determine which displays need a stored-resolution (mode) change.
        // Displays with no stored resolution, no acceptable match, or whose
        // stored mode is already current are left untouched (non-destructive).
        var modeChanges: [(id: CGDirectDisplayID, mode: CGDisplayMode)] = []
        for d in resolved {
            let v = CGDisplayVendorNumber(d.displayID)
            let m = CGDisplayModelNumber(d.displayID)
            guard let target = config.current.resolution(vendor: v, model: m) else { continue }
            guard let mode = bestMatchMode(for: target, among: availableModes(for: d.displayID)) else {
                print("No matching display mode for \(d.name) (vendor:\(v), model:\(m)) — leaving current mode")
                continue
            }
            if isCurrentMode(mode, for: d.displayID) { continue }
            modeChanges.append((d.displayID, mode))
        }

        // PASS 1 — apply mode changes FIRST, in their own transaction, so
        // origins are then computed against the updated point ("looks like")
        // sizes. Otherwise neighbours would be positioned against stale sizes,
        // producing gaps/overlaps. Skipped entirely (no transaction, no screen
        // flash) when nothing needs changing, preserving the single-transaction
        // origins-only path.
        let layoutSource: [ResolvedDisplay]
        if modeChanges.isEmpty {
            layoutSource = resolved
        } else {
            var modeConfig: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&modeConfig) == .success {
                for change in modeChanges {
                    CGConfigureDisplayWithDisplayMode(modeConfig, change.id, change.mode, nil)
                }
                let modeResult = CGCompleteDisplayConfiguration(modeConfig, .permanently)
                if modeResult != .success {
                    print("Mode configuration failed (\(modeResult.rawValue)) — continuing with origin placement")
                }
            } else {
                print("Failed to begin mode configuration — continuing with origin placement")
            }
            // Recompute FROM THE NOW-CURRENT bounds; mode changes can alter the
            // point sizes computeLayout() reads via CGDisplayBounds.
            guard let recomputed = computeLayout() else {
                statusMessage = "Cannot compute layout"
                return
            }
            layoutSource = recomputed
        }

        // PASS 2 — apply origins in a second, balanced transaction.
        let moves = translateForDockOwner(layoutSource, owner: config.current.dock_owner)

        var originConfig: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&originConfig) == .success else {
            statusMessage = "Failed to begin display configuration"
            return
        }
        for move in moves {
            CGConfigureDisplayOrigin(originConfig, move.displayID, Int32(move.x), Int32(move.y))
        }
        let result = CGCompleteDisplayConfiguration(originConfig, .permanently)

        if result == .success {
            isAligned = true
            let desc = moves.map { "\($0.name)→(\($0.x),\($0.y))" }.joined(separator: " ")
            statusMessage = "Aligned: \(desc)"
        } else {
            isAligned = false
            statusMessage = "Configuration failed (\(result.rawValue))"
        }
    }

    // MARK: - Prompt for Unknown Display

    private func promptUser(name: String, vendor: UInt32, model: UInt32) {
        pendingPrompt = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)

            // If another arrangement already knows this display, offer to
            // switch to it as the default action. Saves the user from
            // creating a duplicate arrangement when they're just moving
            // between desks they've already configured.
            let knownArrangement = self.config.arrangementContaining(vendor: vendor, model: model)

            let alert = NSAlert()
            if let arrName = knownArrangement {
                alert.messageText = "Already-Known Display Detected"
                alert.informativeText = """
                    "\(name)" (vendor:\(vendor), model:\(model)) is already in the "\(arrName)" arrangement, but the active one is "\(self.activeArrangement)".

                    Activate "\(arrName)", stack it above the built-in, customize placement, or ignore?
                    """
            } else {
                alert.messageText = "Unknown Display Detected"
                alert.informativeText = """
                    "\(name)" (vendor:\(vendor), model:\(model)) is not in any arrangement.

                    Stack it above the built-in, customize placement, or ignore?
                    """
            }
            alert.alertStyle = .informational

            // Buttons render right-to-left in addButton order; the first
            // becomes the default. When an existing arrangement matches,
            // "Activate <name>" is the most likely intent → first slot.
            if let arrName = knownArrangement {
                alert.addButton(withTitle: "Activate \"\(arrName)\"")
            }
            alert.addButton(withTitle: "Stack Above")
            alert.addButton(withTitle: "Customize…")
            alert.addButton(withTitle: "Ignore")

            // Position alert on built-in display
            if let builtinScreen = NSScreen.screens.first(where: {
                let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return screenNumber.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            }) {
                alert.layout()
                let alertFrame = alert.window.frame
                let x = builtinScreen.frame.midX - alertFrame.width / 2
                let y = builtinScreen.frame.midY - alertFrame.height / 2
                alert.window.setFrameOrigin(NSPoint(x: x, y: y))
                alert.window.makeKeyAndOrderFront(nil)
            }

            let response = alert.runModal()
            let entry = DisplayEntry(name: name, vendor: vendor, model: model)

            // Map the response onto the available actions. Indices shift
            // depending on whether the activate option was added.
            // Button order: [Activate?] Stack Above | Custom Arrange | Ignore
            let activateResponse: NSApplication.ModalResponse? =
                knownArrangement == nil
                ? nil : .alertFirstButtonReturn
            let stackResponse: NSApplication.ModalResponse =
                knownArrangement == nil
                ? .alertFirstButtonReturn : .alertSecondButtonReturn
            let customResponse: NSApplication.ModalResponse =
                knownArrangement == nil
                ? .alertSecondButtonReturn : .alertThirdButtonReturn

            switch response {
            case activateResponse:
                if let arrName = knownArrangement {
                    self.switchArrangement(arrName)
                }
            case stackResponse:
                let switched = self.config.recordStackedFromPrompt(entry)
                if switched {
                    self.publishArrangementState()
                }
                self.refresh()
                if self.autoAlign {
                    self.align()
                }
            case customResponse:
                self.openPlacementEditor(entry: entry)
            default:
                self.config.addIgnored(entry)
                self.refresh()
            }
            self.pendingPrompt = false
        }
    }

    // MARK: - Placement Editor

    private func openPlacementEditor(entry: DisplayEntry) {
        guard let layout = computeLayout() else { return }
        let displays = activeDisplays()
        guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return }

        // Build CanvasDisplay array from resolved layout
        let canvasDisplays = layout.map { resolved in
            CanvasDisplay(
                id: resolved.name,
                displayID: resolved.displayID,
                name: resolved.name == "builtin" ? "MacBook" : resolved.name,
                x: resolved.x,
                y: resolved.y,
                width: resolved.width,
                height: resolved.height,
                isBuiltin: resolved.name == "builtin"
            )
        }

        // Get new display's dimensions
        let newDisplayID = displays.first {
            CGDisplayIsBuiltin($0) == 0
                && DisplayID(vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0)) == entry.displayID
        }
        let width = newDisplayID.map { Int(CGDisplayPixelsWide($0)) } ?? 1920
        let height = newDisplayID.map { Int(CGDisplayPixelsHigh($0)) } ?? 1080

        Task { @MainActor in
            let coordinator = PlacementCoordinator(
                arrangement: canvasDisplays,
                newDisplay: entry,
                width: width,
                height: height,
                dockOwner: config.current.effectiveDockOwner
            )
            coordinator.onCommit = { [weak self] in
                self?.config = Config.load()
                self?.publishArrangementState()
                self?.refresh()
                if self?.autoAlign == true {
                    self?.align()
                }
            }
            PlacementWindow.show(coordinator: coordinator, on: builtinID)
        }
    }

    /// Opens the arrangement editor for the current active arrangement (from menubar).
    func openArrangementEditor() {
        guard let layout = computeLayout() else { return }
        let displays = activeDisplays()
        guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return }

        let canvasDisplays = layout.map { resolved in
            CanvasDisplay(
                id: resolved.name,
                displayID: resolved.displayID,
                name: resolved.name == "builtin" ? "MacBook" : resolved.name,
                x: resolved.x,
                y: resolved.y,
                width: resolved.width,
                height: resolved.height,
                isBuiltin: resolved.name == "builtin"
            )
        }

        Task { @MainActor in
            let coordinator = PlacementCoordinator(
                arrangement: canvasDisplays,
                dockOwner: config.current.effectiveDockOwner
            )
            coordinator.onCommit = { [weak self] in
                self?.config = Config.load()
                self?.publishArrangementState()
                self?.refresh()
                if self?.autoAlign == true {
                    self?.align()
                }
            }
            PlacementWindow.show(coordinator: coordinator, on: builtinID)
        }
    }

    // MARK: - Display Change Callback

    private func startWatching() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, pointer)
    }
}

// Free function required for @convention(c) callback
private func displayReconfigured(
    _ displayID: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    guard flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
    guard let userInfo else { return }

    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        manager.refresh()
        if flags.contains(.addFlag), manager.autoAlign, manager.hasConfiguredExternals() {
            manager.align()
        }
    }
}
