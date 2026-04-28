import Foundation
import CoreGraphics
import AppKit

/// Resolved rectangle for a display during layout computation.
struct ResolvedDisplay {
    let name: String
    let displayID: CGDirectDisplayID
    var x: Int
    var y: Int
    let width: Int
    let height: Int
}

final class DisplayManager: ObservableObject {
    @Published var externalName: String?
    @Published var isAligned = false
    @Published var autoAlign = true
    @Published var statusMessage = "Starting..."

    private var config: Config
    private var pendingPrompt = false

    init() {
        config = Config.load()
        startWatching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
            if let self = self, self.autoAlign, self.hasConfiguredExternals() {
                self.align()
            }
        }
    }

    // MARK: - Display Enumeration

    private func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - Display Identification

    func identifyDisplay(_ displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)

        // Check all config lists
        if let entry = config.stacked.first(where: { $0.vendor == vendor && $0.model == model }) {
            return entry.name
        }
        if let entry = config.ignored.first(where: { $0.vendor == vendor && $0.model == model }) {
            return entry.name
        }
        if let entry = config.flexible.first(where: { $0.vendor == vendor && $0.model == model }) {
            return entry.name
        }

        // Fallback: vendor-based name
        return "\(Vendor.name(for: vendor)) [model:\(model)]"
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
        guard let layout = computeLayout() else {
            statusMessage = "Layout computation failed"
            isAligned = false
            return
        }

        // Compare computed layout against actual positions
        var allAligned = true
        for resolved in layout where CGDisplayIsBuiltin(resolved.displayID) == 0 {
            let actual = CGDisplayBounds(resolved.displayID)
            if Int(actual.origin.x) != resolved.x || Int(actual.origin.y) != resolved.y {
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
        for entry in config.stacked {
            guard let id = displays.first(where: {
                CGDisplayIsBuiltin($0) == 0
                && CGDisplayVendorNumber($0) == entry.vendor
                && CGDisplayModelNumber($0) == entry.model
            }) else { continue }

            let bounds = CGDisplayBounds(id)
            let w = Int(bounds.width)
            let h = Int(bounds.height)
            let x = (Int(builtinBounds.width) - w) / 2
            let y = -h

            resolved.append(ResolvedDisplay(name: entry.name, displayID: id, x: x, y: y, width: w, height: h))
        }

        // Resolve flexible displays in dependency order
        var pending = config.flexible.filter { flex in
            displays.contains(where: {
                CGDisplayIsBuiltin($0) == 0
                && CGDisplayVendorNumber($0) == flex.vendor
                && CGDisplayModelNumber($0) == flex.model
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

                guard let id = displays.first(where: {
                    CGDisplayIsBuiltin($0) == 0
                    && CGDisplayVendorNumber($0) == flex.vendor
                    && CGDisplayModelNumber($0) == flex.model
                }) else { continue }

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

    // MARK: - Align

    func align() {
        guard let layout = computeLayout() else {
            statusMessage = "Cannot compute layout"
            return
        }

        // Only move externals (not the builtin)
        let moves = layout.filter { CGDisplayIsBuiltin($0.displayID) == 0 }
        guard !moves.isEmpty else {
            statusMessage = "No displays to move"
            return
        }

        var cgConfig: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cgConfig) == .success else {
            statusMessage = "Failed to begin display configuration"
            return
        }

        for move in moves {
            CGConfigureDisplayOrigin(cgConfig, move.displayID, Int32(move.x), Int32(move.y))
        }

        let result = CGCompleteDisplayConfiguration(cgConfig, .permanently)

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
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Unknown Display Detected"
            alert.informativeText = "\"\(name)\" (vendor:\(vendor), model:\(model)) is not in your config.\n\nShould it be stacked (centered above the built-in display)?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Stack Above")
            alert.addButton(withTitle: "Ignore")

            let response = alert.runModal()
            let entry = DisplayEntry(name: name, vendor: vendor, model: model)

            if response == .alertFirstButtonReturn {
                self?.config.addStacked(entry)
                self?.refresh()
                if self?.autoAlign == true {
                    self?.align()
                }
            } else {
                self?.config.addIgnored(entry)
                self?.refresh()
            }
            self?.pendingPrompt = false
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
