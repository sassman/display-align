import Foundation
import CoreGraphics
import AppKit

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
            if let self = self, self.autoAlign, self.isStacked() {
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

        // Check config first
        if let entry = config.stacked.first(where: { $0.vendor == vendor && $0.model == model }) {
            return entry.name
        }
        if let entry = config.ignored.first(where: { $0.vendor == vendor && $0.model == model }) {
            return entry.name
        }

        // Fallback: describe by vendor
        let vendorName: String
        switch vendor {
        case 4268:  vendorName = "Dell"
        case 1552:  vendorName = "Apple"
        case 220:   vendorName = "LG"
        case 2513:  vendorName = "BenQ"
        case 1267:  vendorName = "Samsung"
        case 5765:  vendorName = "Lenovo"
        default:    vendorName = "Vendor(\(vendor))"
        }
        return "\(vendorName) [model:\(model)]"
    }

    /// Check if the current external is in the stacked list.
    func isStacked() -> Bool {
        let displays = activeDisplays()
        guard let externalID = displays.first(where: { CGDisplayIsBuiltin($0) == 0 }) else {
            return false
        }
        let vendor = CGDisplayVendorNumber(externalID)
        let model  = CGDisplayModelNumber(externalID)
        return config.isStacked(vendor: vendor, model: model)
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
        guard let externalID = externals.first else {
            externalName = nil
            isAligned = false
            statusMessage = "No external display"
            return
        }

        let vendor = CGDisplayVendorNumber(externalID)
        let model  = CGDisplayModelNumber(externalID)
        let name = identifyDisplay(externalID)
        externalName = name

        if config.isIgnored(vendor: vendor, model: model) {
            isAligned = false
            statusMessage = "Ignored"
            return
        }

        if config.isStacked(vendor: vendor, model: model) {
            checkAlignment()
            return
        }

        // Unknown display — prompt user
        isAligned = false
        statusMessage = "Unknown display"
        if !pendingPrompt {
            promptUser(name: name, vendor: vendor, model: model)
        }
    }

    private func checkAlignment() {
        let displays = activeDisplays()
        guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let externalID = displays.first(where: { CGDisplayIsBuiltin($0) == 0 })
        else { return }

        let builtinBounds  = CGDisplayBounds(builtinID)
        let externalBounds = CGDisplayBounds(externalID)

        let expectedX = Int(builtinBounds.width  - externalBounds.width) / 2
        let expectedY = -Int(externalBounds.height)

        let currentX = Int(externalBounds.origin.x)
        let currentY = Int(externalBounds.origin.y)

        isAligned = currentX == expectedX && currentY == expectedY
        statusMessage = isAligned
            ? "Aligned at (\(currentX), \(currentY))"
            : "Not aligned — at (\(currentX), \(currentY))"
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

    // MARK: - Align

    func align() {
        let displays = activeDisplays()
        guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let externalID = displays.first(where: { CGDisplayIsBuiltin($0) == 0 })
        else {
            statusMessage = "Need both displays connected"
            return
        }

        let vendor = CGDisplayVendorNumber(externalID)
        let model  = CGDisplayModelNumber(externalID)

        guard config.isStacked(vendor: vendor, model: model) else {
            statusMessage = "External is not in stacked list"
            return
        }

        let builtinBounds  = CGDisplayBounds(builtinID)
        let externalBounds = CGDisplayBounds(externalID)

        let extX = Int32(Int(builtinBounds.width  - externalBounds.width) / 2)
        let extY = Int32(-Int(externalBounds.height))

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            statusMessage = "Failed to begin display configuration"
            return
        }

        CGConfigureDisplayOrigin(config, externalID, extX, extY)

        let result = CGCompleteDisplayConfiguration(config, .permanently)

        if result == .success {
            isAligned = true
            statusMessage = "Aligned at (\(extX), \(extY))"
        } else {
            isAligned = false
            statusMessage = "Configuration failed (\(result.rawValue))"
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
        if flags.contains(.addFlag), manager.autoAlign, manager.isStacked() {
            manager.align()
        }
    }
}
