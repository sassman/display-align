import AppKit
import CoreGraphics
import Foundation

/// Resolve a `CGDisplayVendorNumber` to a human-readable manufacturer name.
///
/// `CGDisplayVendorNumber` exposes EDID bytes 8-9 (ISO 9070 / EDID v1.4
/// §3.4), which pack a 3-letter PnP manufacturer code as
/// `(c1 << 10) | (c2 << 5) | c3` where each letter is `A...Z` mapped to
/// `1...26`. Decoding back yields the canonical PnP ID, which we look up
/// in `pnpVendors`.
///
/// Some displays don't surface a valid EDID record (Apple-Silicon-managed
/// LG UltraFines, certain TVs, capture-card chains). For those, macOS
/// substitutes IOKit's framebuffer vendor — not always EDID-encoded — and
/// we fall back to `empiricalVendors` for values observed in the wild.
enum Vendor {
    /// Friendly names for PnP codes that don't match the brand 1:1.
    /// Codes whose 3-letter form already reads as the brand (e.g. AOC, IBM,
    /// MSI, NEC) aren't listed — `name(for:)` returns the decoded PnP code
    /// directly when no override is found.
    private static let pnpVendors: [String: String] = [
        "ACI": "ASUS",  // Asustek Computer Inc
        "ACR": "Acer",
        "APP": "Apple",
        "BNQ": "BenQ",
        "CMN": "Innolux",  // Chimei Innolux — laptop panels
        "DEL": "Dell",
        "ENC": "Eizo",
        "GSM": "LG",  // GoldStar Mfg, LG's monitor PnP code
        "HWP": "HP",
        "IVM": "Iiyama",
        "LEN": "Lenovo",
        "LGD": "LG Display",  // LG laptop / panel maker
        "LGE": "LG",
        "PHL": "Philips",
        "SAM": "Samsung",
        "SDC": "Samsung",  // Samsung Display Co — panel maker
        "SHP": "Sharp",
        "SNY": "Sony",
        "TSB": "Toshiba",
        "VSC": "ViewSonic",
    ]

    /// Vendor numbers observed in the wild that don't decode as EDID PnP.
    /// Keep here when a real display reports them so identification still works.
    private static let empiricalVendors: [UInt32: String] = [
        220: "LG",
        1267: "Samsung",
        5765: "Lenovo",
    ]

    /// Decode an EDID vendor number to its 3-letter PnP code, or `nil` if
    /// the value isn't a valid `[A-Z]{3}` triple.
    static func pnpCode(for vendor: UInt32) -> String? {
        let c1 = Int((vendor >> 10) & 0x1F)
        let c2 = Int((vendor >> 5) & 0x1F)
        let c3 = Int(vendor & 0x1F)
        guard (1...26).contains(c1),
            (1...26).contains(c2),
            (1...26).contains(c3)
        else { return nil }
        let scalars = [c1, c2, c3].compactMap { UnicodeScalar(64 + $0) }
        guard scalars.count == 3 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Resolve a vendor number to a manufacturer name.
    ///
    /// Lookup order:
    /// 1. EDID PnP decode → friendly name override (e.g. `DEL` → `"Dell"`).
    /// 2. EDID PnP decode → 3-letter code itself (e.g. `AOC` → `"AOC"`).
    /// 3. Empirical map for known non-EDID vendor numbers.
    /// 4. `"Vendor(<n>)"` for fully unknown values.
    static func name(for vendor: UInt32) -> String {
        if let pnp = pnpCode(for: vendor) {
            return pnpVendors[pnp] ?? pnp
        }
        if let name = empiricalVendors[vendor] {
            return name
        }
        return "Vendor(\(vendor))"
    }

    /// Build a human-readable display label of the form `"<Vendor> <Model>"`,
    /// e.g. `"AOC U2790B"` or `"ASUS ROG PG348Q"`. The model part comes from
    /// `NSScreen.localizedName` (same string macOS shows in System Settings →
    /// Displays). Falls back to `"<Vendor> [model:<n>]"` when no `NSScreen`
    /// matches — primarily virtual or capture-card displays.
    static func humanLabel(for displayID: CGDirectDisplayID) -> String {
        let vendor = name(for: CGDisplayVendorNumber(displayID))
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        if let model = screen?.localizedName, !model.isEmpty {
            return "\(vendor) \(model)"
        }
        return "\(vendor) [model:\(CGDisplayModelNumber(displayID))]"
    }

    /// Best-effort human label when only `(vendor, model)` is known and no
    /// `CGDirectDisplayID` is on hand (e.g. during config migration). Walks
    /// connected screens for a fingerprint match and delegates to
    /// `humanLabel(for:)`. Returns `nil` if no connected display matches.
    static func humanLabel(forVendor vendor: UInt32, model: UInt32) -> String? {
        for screen in NSScreen.screens {
            guard
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                CGDisplayVendorNumber(id) == vendor,
                CGDisplayModelNumber(id) == model
            else { continue }
            return humanLabel(for: id)
        }
        return nil
    }
}
