import Foundation

/// A display's stable identity: the (vendor, model) pair reported by
/// CoreGraphics. Two physically identical monitors share one `DisplayID` —
/// the same keying limitation that runs through stacked/flexible/resolution
/// storage. `packed` folds the pair into a single 64-bit key for set/dict use.
struct DisplayID: Equatable, Hashable {
    let vendor: UInt32
    let model: UInt32
    var packed: UInt64 { (UInt64(vendor) << 32) | UInt64(model) }
}

/// Anything carrying a (vendor, model) pair. Gives a free `displayID` so
/// identity comparisons collapse to a single `==` instead of the repeated
/// `vendor == … && model == …` predicate.
protocol DisplayIdentified {
    var vendor: UInt32 { get }
    var model: UInt32 { get }
}
extension DisplayIdentified {
    var displayID: DisplayID { DisplayID(vendor: vendor, model: model) }
}

struct DisplayEntry: Codable, Equatable {
    let name: String
    let vendor: UInt32
    let model: UInt32
}

struct FlexibleDisplay: Codable, Equatable {
    let name: String
    let vendor: UInt32
    let model: UInt32
    let position: Position
    let relative_to: String  // "builtin" or a display name
    let align: Alignment
    let offset: Int?  // pixels from the align anchor, default 0
    let rotation: Int?  // 0, 90, 270 — informational for now

    enum Position: String, Codable {
        case above, below, left, right
    }

    enum Alignment: String, Codable {
        case top, center, bottom  // for left/right positioning
        case left_edge = "left"  // for above/below positioning
        case right_edge = "right"  // for above/below positioning
        // "center" works for both axes
    }

    var effectiveOffset: Int { offset ?? 0 }
}

/// A captured display mode for one display, keyed by (vendor, model).
///
/// Stores full fidelity so a mode can be re-selected on another boot:
/// the scaled "looks like" point size (`width`/`height`), the native
/// pixel dimensions (`pixelWidth`/`pixelHeight`), and the refresh rate.
/// Keyed uniformly by (vendor, model) for both the built-in and external
/// displays.
struct DisplayResolution: Codable, Equatable {
    let vendor: UInt32
    let model: UInt32
    let width: Int  // scaled ("looks like") point size
    let height: Int
    let pixelWidth: Int  // native pixels
    let pixelHeight: Int
    let refreshHz: Double
}

// (vendor, model) already stored on each of these — conformance is free and
// adds no properties or coding keys, so the on-disk JSON is unchanged.
extension DisplayEntry: DisplayIdentified {}
extension FlexibleDisplay: DisplayIdentified {}
extension DisplayResolution: DisplayIdentified {}

/// Collapse resolutions that share a (vendor, model) key to a single entry
/// (first seen wins). Identical monitors report the same (vendor, model), so
/// only one stored mode is meaningful and both get driven to it — see
/// `Arrangement.resolution(vendor:model:)`. Both capture paths dedupe on this
/// key so the array never carries unreachable duplicate-keyed entries.
func dedupedResolutions(_ resolutions: [DisplayResolution]) -> [DisplayResolution] {
    var seen = Set<UInt64>()
    var result: [DisplayResolution] = []
    for r in resolutions {
        let key = r.displayID.packed
        if seen.insert(key).inserted {
            result.append(r)
        }
    }
    return result
}

/// A named layout: which displays are stacked above the built-in screen and
/// which ones use relative positioning. `ignored` is intentionally **not**
/// part of an arrangement — it's a global "leave-alone" set that doesn't
/// vary between desks.
struct Arrangement: Codable, Equatable, Identifiable {
    let name: String
    var stacked: [DisplayEntry]
    var flexible: [FlexibleDisplay]
    var dock_owner: String?
    /// Per-display captured resolutions. `nil` (or an absent entry for a
    /// given display) means "leave that display's resolution alone" on
    /// activate — mirrors the optional `dock_owner` semantics.
    var resolutions: [DisplayResolution]?

    var id: String { name }

    static let defaultName = "default"

    static func empty(named name: String = defaultName) -> Arrangement {
        Arrangement(name: name, stacked: [], flexible: [])
    }

    init(
        name: String,
        stacked: [DisplayEntry] = [],
        flexible: [FlexibleDisplay] = [],
        dock_owner: String? = nil,
        resolutions: [DisplayResolution]? = nil
    ) {
        self.name = name
        self.stacked = stacked
        self.flexible = flexible
        self.dock_owner = dock_owner
        self.resolutions = resolutions
    }

    private enum CodingKeys: String, CodingKey {
        case name, stacked, flexible, dock_owner, resolutions
    }

    /// Tolerant decode: hand-edited configs frequently omit `stacked` or
    /// `flexible` entirely when an arrangement uses only one of them.
    /// Missing arrays decode as empty so the user's data isn't blown away
    /// by the seed-and-save fallback.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        stacked = try c.decodeIfPresent([DisplayEntry].self, forKey: .stacked) ?? []
        flexible = try c.decodeIfPresent([FlexibleDisplay].self, forKey: .flexible) ?? []
        dock_owner = try c.decodeIfPresent(String.self, forKey: .dock_owner)
        resolutions = try c.decodeIfPresent([DisplayResolution].self, forKey: .resolutions)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(stacked, forKey: .stacked)
        try c.encode(flexible, forKey: .flexible)
        try c.encodeIfPresent(dock_owner, forKey: .dock_owner)
        try c.encodeIfPresent(resolutions, forKey: .resolutions)
    }

    /// Effective dock owner name. "builtin" if unset or explicitly set to "builtin".
    var effectiveDockOwner: String { dock_owner ?? "builtin" }

    /// The stored resolution for a display keyed by (vendor, model), or `nil`
    /// when none was captured — in which case that display is left untouched.
    ///
    /// Resolutions are keyed by (vendor, model): two identical monitors (same
    /// vendor + model) collapse to a single stored mode and both are driven to
    /// it — the same keying limitation as stacked/flexible entries. Capture
    /// dedupes on this key (see `dedupedResolutions`), so `.first` is
    /// authoritative here.
    func resolution(vendor: UInt32, model: UInt32) -> DisplayResolution? {
        let id = DisplayID(vendor: vendor, model: model)
        return resolutions?.first { $0.displayID == id }
    }
}

struct Config: Codable, Equatable {
    /// Name of the currently active arrangement. Persisted across launches.
    var active: String
    /// Globally ignored displays (apply to every arrangement).
    var ignored: [DisplayEntry]
    /// Named arrangements. Always non-empty after `load()`.
    var arrangements: [Arrangement]

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/display-align")
    static let configFile = configDir.appendingPathComponent("config.json")

    init(active: String, ignored: [DisplayEntry] = [], arrangements: [Arrangement] = []) {
        self.active = active
        self.ignored = ignored
        self.arrangements = arrangements
    }

    private enum CodingKeys: String, CodingKey {
        case active, ignored, arrangements
    }

    /// Tolerant decode: hand-edited configs may omit fields they don't
    /// use. `normalize()` after load supplies a default arrangement if
    /// needed and points `active` at a real one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(String.self, forKey: .active) ?? Arrangement.defaultName
        ignored = try c.decodeIfPresent([DisplayEntry].self, forKey: .ignored) ?? []
        arrangements = try c.decodeIfPresent([Arrangement].self, forKey: .arrangements) ?? []
    }

    /// The arrangement matching `active`, or the first arrangement if `active`
    /// no longer resolves (e.g. user renamed it). Never `nil` after `load()`.
    var current: Arrangement {
        arrangements.first { $0.name == active }
            ?? arrangements.first
            ?? Arrangement.empty()
    }

    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configFile.path),
            let data = try? Data(contentsOf: configFile)
        else {
            return seedAndSave()
        }

        // Pick the schema by the shape of the top-level object: presence of
        // an `arrangements` key marks the post-1.3 nested layout. Anything
        // else with `stacked`/`flexible`/`ignored` at the top is the legacy
        // flat layout. Without this gate a hand-edited new-format file
        // missing `arrangements` could be misread as legacy (and vice
        // versa), and the saved-and-overwrite fallback would silently
        // discard the user's data.
        let topLevelKeys = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if topLevelKeys?["arrangements"] != nil,
            var config = try? JSONDecoder().decode(Config.self, from: data)
        {
            config.normalize()
            if config.migrateAutoGeneratedNames() {
                config.save()
            }
            return config
        }

        if let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data) {
            var config = legacy.upgraded()
            config.normalize()
            _ = config.migrateAutoGeneratedNames()
            config.save()
            return config
        }

        // Unparseable. *Don't* clobber the file — return a synthesized
        // empty config so the app starts but the user's broken JSON stays
        // on disk for them to inspect / fix.
        var fallback = Config(active: Arrangement.defaultName)
        fallback.normalize()
        return fallback
    }

    /// First-launch seed: one `default` arrangement with the canonical
    /// stacked Dell entry, no flexible or ignored displays.
    private static func seedAndSave() -> Config {
        let seed = Config(
            active: Arrangement.defaultName,
            ignored: [],
            arrangements: [
                Arrangement(
                    name: Arrangement.defaultName,
                    stacked: [DisplayEntry(name: "DELL P3424WEB", vendor: 4268, model: 17092)],
                    flexible: []
                )
            ]
        )
        seed.save()
        return seed
    }

    /// Defensive fixups applied after every load: ensure at least one
    /// arrangement exists, and that `active` points at a real one.
    private mutating func normalize() {
        if arrangements.isEmpty {
            arrangements = [Arrangement.empty()]
        }
        if !arrangements.contains(where: { $0.name == active }) {
            active = arrangements[0].name
        }
    }

    /// Refresh entries whose `name` is an auto-generated placeholder.
    /// User-customized names (e.g. `"DELL P3424WEB"`) don't match any of
    /// the known patterns and stay put. Each arrangement has its own
    /// rename map so `flexible.relative_to` cross-references inside that
    /// arrangement remain consistent. Returns `true` if any entry was
    /// rewritten — caller should `save()`.
    ///
    /// Patterns handled (oldest → newest):
    ///   1. `Vendor(<n>) [model:<m>]` — vendor name unknown.
    ///   2. `<canonical-vendor> [model:<m>]` — current pre-localizedName
    ///      fallback (e.g. `"AOC [model:10128]"`).
    ///
    /// Both upgrade to `<canonical-vendor> <NSScreen.localizedName>`
    /// (e.g. `"AOC U2790B"`) when the display is connected. If it isn't,
    /// pattern 1 still gets the canonical vendor name lifted in (becoming
    /// pattern 2); pattern 2 stays untouched until the display is plugged
    /// in again.
    mutating func migrateAutoGeneratedNames() -> Bool {
        func regenerated(_ name: String, vendor: UInt32, model: UInt32) -> String? {
            let canonicalVendor = Vendor.name(for: vendor)
            let isLegacy = name.range(of: #"^Vendor\(\d+\) \[model:\d+\]$"#, options: .regularExpression) != nil
            let isCurrent = name == "\(canonicalVendor) [model:\(model)]"
            guard isLegacy || isCurrent else { return nil }

            if let upgraded = Vendor.humanLabel(forVendor: vendor, model: model) {
                return upgraded == name ? nil : upgraded
            }
            // Display not connected: only legacy entries can still be
            // partially upgraded (lift to the canonical-vendor format).
            guard isLegacy else { return nil }
            let lifted = "\(canonicalVendor) [model:\(model)]"
            return lifted == name ? nil : lifted
        }

        var changed = false

        // Global ignored: simple name-only rewrite (not referenced elsewhere).
        let ignoredRenames = Self.collectRenames(from: ignored, regen: regenerated)
        if !ignoredRenames.isEmpty {
            ignored = ignored.map { e in
                guard let newName = ignoredRenames[e.name] else { return e }
                return DisplayEntry(name: newName, vendor: e.vendor, model: e.model)
            }
            changed = true
        }

        // Per-arrangement: rename map is local so relative_to references
        // are remapped against the same arrangement's renamed entries.
        for i in arrangements.indices {
            var renames = Self.collectRenames(from: arrangements[i].stacked, regen: regenerated)
            for f in arrangements[i].flexible {
                if let newName = regenerated(f.name, vendor: f.vendor, model: f.model) {
                    renames[f.name] = newName
                }
            }
            if renames.isEmpty { continue }

            arrangements[i].stacked = arrangements[i].stacked.map { e in
                guard let newName = renames[e.name] else { return e }
                return DisplayEntry(name: newName, vendor: e.vendor, model: e.model)
            }
            arrangements[i].flexible = arrangements[i].flexible.map { f in
                let newName = renames[f.name] ?? f.name
                let newRelative = renames[f.relative_to] ?? f.relative_to
                guard newName != f.name || newRelative != f.relative_to else { return f }
                return FlexibleDisplay(
                    name: newName, vendor: f.vendor, model: f.model,
                    position: f.position, relative_to: newRelative,
                    align: f.align, offset: f.offset, rotation: f.rotation
                )
            }
            changed = true
        }
        return changed
    }

    private static func collectRenames(
        from entries: [DisplayEntry],
        regen: (String, UInt32, UInt32) -> String?
    ) -> [String: String] {
        var map: [String: String] = [:]
        for e in entries {
            if let newName = regen(e.name, e.vendor, e.model) {
                map[e.name] = newName
            }
        }
        return map
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // No `.sortedKeys`: emit keys in encode order so each object leads
            // with `name` (Arrangement/DisplayEntry/FlexibleDisplay) — you can
            // eyeball where one arrangement ends and the next begins. Order is
            // still deterministic (declaration order), just not alphabetical.
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(self)
            try data.write(to: Self.configFile, options: .atomic)
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    // MARK: - Membership checks (always against the active arrangement)

    func isStacked(vendor: UInt32, model: UInt32) -> Bool {
        let id = DisplayID(vendor: vendor, model: model)
        return current.stacked.contains { $0.displayID == id }
    }

    func isIgnored(vendor: UInt32, model: UInt32) -> Bool {
        let id = DisplayID(vendor: vendor, model: model)
        return ignored.contains { $0.displayID == id }
    }

    func isFlexible(vendor: UInt32, model: UInt32) -> Bool {
        let id = DisplayID(vendor: vendor, model: model)
        return current.flexible.contains { $0.displayID == id }
    }

    func isKnown(vendor: UInt32, model: UInt32) -> Bool {
        isStacked(vendor: vendor, model: model)
            || isIgnored(vendor: vendor, model: model)
            || isFlexible(vendor: vendor, model: model)
    }

    /// First arrangement *other than the active one* whose `stacked` or
    /// `flexible` already references the given display, or `nil` if none
    /// does. Iteration follows the order in the config file — first match
    /// wins. The active arrangement is skipped because the unknown-display
    /// prompt already only fires when the display isn't there.
    func arrangementContaining(vendor: UInt32, model: UInt32) -> String? {
        let id = DisplayID(vendor: vendor, model: model)
        for arr in arrangements where arr.name != active {
            if arr.stacked.contains(where: { $0.displayID == id })
                || arr.flexible.contains(where: { $0.displayID == id })
            {
                return arr.name
            }
        }
        return nil
    }

    // MARK: - Mutations

    /// Record a "Stack Above" choice from the unknown-display prompt.
    ///
    /// - If the current arrangement is empty (no `stacked`, no `flexible`),
    ///   the new display is added to it in place — the seed / fresh-empty
    ///   case where the user is filling out an arrangement for the first
    ///   time.
    /// - Otherwise, a clone of the current arrangement is appended to the
    ///   list with the new display added to its `stacked`, and `active`
    ///   switches to the clone. This protects an existing layout from
    ///   being silently mutated by a stray "Stack Above" click.
    ///
    /// Returns `true` when a new arrangement was created (caller can use
    /// it to gate "switched arrangement" follow-up like a re-align).
    @discardableResult
    mutating func recordStackedFromPrompt(_ entry: DisplayEntry) -> Bool {
        guard !isKnown(vendor: entry.vendor, model: entry.model) else { return false }
        guard let activeIdx = arrangements.firstIndex(where: { $0.name == active }) else { return false }
        let cur = arrangements[activeIdx]

        if cur.stacked.isEmpty, cur.flexible.isEmpty {
            arrangements[activeIdx].stacked.append(entry)
            save()
            return false
        }

        let cloneName = uniqueArrangementName(basedOn: cur.name)
        arrangements.append(
            Arrangement(
                name: cloneName,
                stacked: cur.stacked + [entry],
                flexible: cur.flexible
            ))
        active = cloneName
        save()
        return true
    }

    /// Build a name that doesn't collide with any existing arrangement,
    /// extending `base` with `" 2"`, `" 3"`, ... until it's unique.
    private func uniqueArrangementName(basedOn base: String) -> String {
        let taken = Set(arrangements.map(\.name))
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Add to the global ignored list. No-op if already known.
    mutating func addIgnored(_ entry: DisplayEntry) {
        guard !isKnown(vendor: entry.vendor, model: entry.model) else { return }
        ignored.append(entry)
        save()
    }

    /// Switch the active arrangement. Returns `true` when the active name
    /// actually changed (caller can use this to gate a refresh / re-align).
    mutating func switchTo(_ name: String) -> Bool {
        guard active != name,
            arrangements.contains(where: { $0.name == name })
        else { return false }
        active = name
        save()
        return true
    }
}

/// Pre-arrangement schema (top-level `stacked`/`ignored`/`flexible`).
/// Used only by `Config.load()` to upgrade legacy config files.
private struct LegacyConfig: Codable {
    var stacked: [DisplayEntry]
    var ignored: [DisplayEntry]
    var flexible: [FlexibleDisplay]

    func upgraded() -> Config {
        Config(
            active: Arrangement.defaultName,
            ignored: ignored,
            arrangements: [
                Arrangement(
                    name: Arrangement.defaultName,
                    stacked: stacked,
                    flexible: flexible
                )
            ]
        )
    }
}
