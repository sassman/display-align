import Foundation

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
    let relative_to: String       // "builtin" or a display name
    let align: Alignment
    let offset: Int?              // pixels from the align anchor, default 0
    let rotation: Int?            // 0, 90, 270 — informational for now

    enum Position: String, Codable {
        case above, below, left, right
    }

    enum Alignment: String, Codable {
        case top, center, bottom    // for left/right positioning
        case left_edge = "left"     // for above/below positioning
        case right_edge = "right"   // for above/below positioning
        // "center" works for both axes
    }

    var effectiveOffset: Int { offset ?? 0 }
}

struct Config: Codable {
    var stacked: [DisplayEntry]
    var ignored: [DisplayEntry]
    var flexible: [FlexibleDisplay]

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/display-align")
    static let configFile = configDir.appendingPathComponent("config.json")

    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            // First run: seed with the known Dell in stacked
            let initial = Config(
                stacked: [DisplayEntry(name: "DELL P3424WEB", vendor: 4268, model: 17092)],
                ignored: [],
                flexible: []
            )
            initial.save()
            return initial
        }
        return config
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: Self.configFile, options: .atomic)
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    func isStacked(vendor: UInt32, model: UInt32) -> Bool {
        stacked.contains { $0.vendor == vendor && $0.model == model }
    }

    func isIgnored(vendor: UInt32, model: UInt32) -> Bool {
        ignored.contains { $0.vendor == vendor && $0.model == model }
    }

    func isFlexible(vendor: UInt32, model: UInt32) -> Bool {
        flexible.contains { $0.vendor == vendor && $0.model == model }
    }

    func isKnown(vendor: UInt32, model: UInt32) -> Bool {
        isStacked(vendor: vendor, model: model)
            || isIgnored(vendor: vendor, model: model)
            || isFlexible(vendor: vendor, model: model)
    }

    mutating func addStacked(_ entry: DisplayEntry) {
        guard !isKnown(vendor: entry.vendor, model: entry.model) else { return }
        stacked.append(entry)
        save()
    }

    mutating func addIgnored(_ entry: DisplayEntry) {
        guard !isKnown(vendor: entry.vendor, model: entry.model) else { return }
        ignored.append(entry)
        save()
    }
}
