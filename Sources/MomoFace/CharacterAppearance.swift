import Foundation

/// A colour stored as `#RRGGBB` in character packs.
public struct RGBColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Components from 0 to 255.
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` or `RRGGBB`.
    public init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF)
        green = Double((value >> 8) & 0xFF)
        blue = Double(value & 0xFF)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGBColor(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a colour like #1A2B3C, got \(text)")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// Mixes towards `other` by `amount` (0...1).
    public func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        let t = min(1, max(0, amount))
        return RGBColor(
            red: red + (other.red - red) * t, green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t)
    }
}

/// How a character looks. Built-in looks ship with Momo; more can be added as JSON files
/// (see `docs/character-packs.md`).
public struct CharacterAppearance: Codable, Sendable, Hashable, Identifiable {
    public enum EyeShape: String, Codable, Sendable, CaseIterable {
        /// Tall rounded capsules.
        case pill
        /// Circles.
        case round
        /// Rounded squares, for robots.
        case square
    }

    public enum Accessory: String, Codable, Sendable, CaseIterable {
        case none
        case whiskers
        case glasses
        case bow
        case freckles
        case sprout
    }

    public var id: String
    /// Names by language code, with "en" as the fallback.
    public var name: [String: String]
    public var bodyColor: RGBColor
    /// A fixed eye colour; `nil` uses the brain's colour (white when thinking locally).
    public var eyeColor: RGBColor?
    public var blushColor: RGBColor
    public var eyeShape: EyeShape
    public var accessory: Accessory
    public var accessoryColor: RGBColor?

    public init(
        id: String, name: [String: String], bodyColor: RGBColor, eyeColor: RGBColor? = nil,
        blushColor: RGBColor = RGBColor(red: 255, green: 143, blue: 163),
        eyeShape: EyeShape = .pill, accessory: Accessory = .none, accessoryColor: RGBColor? = nil
    ) {
        self.id = id
        self.name = name
        self.bodyColor = bodyColor
        self.eyeColor = eyeColor
        self.blushColor = blushColor
        self.eyeShape = eyeShape
        self.accessory = accessory
        self.accessoryColor = accessoryColor
    }

    public func localizedName(for languageCode: String?) -> String {
        languageCode.flatMap { name[$0] } ?? name["en"] ?? id
    }

    /// Whether the body is light, so outlines and rim light should be dark.
    public var hasLightBody: Bool {
        (bodyColor.red * 0.299 + bodyColor.green * 0.587 + bodyColor.blue * 0.114) > 150
    }

    // MARK: - Built-in characters

    public static let classic = CharacterAppearance(
        id: "classic", name: ["en": "Classic", "tr": "Klasik"],
        bodyColor: RGBColor(red: 18, green: 19, blue: 24))

    public static let snow = CharacterAppearance(
        id: "snow", name: ["en": "Snow", "tr": "Kar"],
        bodyColor: RGBColor(red: 244, green: 244, blue: 247),
        eyeColor: RGBColor(red: 30, green: 31, blue: 38))

    public static let kitty = CharacterAppearance(
        id: "kitty", name: ["en": "Kitty", "tr": "Pisi"],
        bodyColor: RGBColor(red: 44, green: 44, blue: 52), eyeShape: .round,
        accessory: .whiskers, accessoryColor: RGBColor(red: 220, green: 220, blue: 230))

    public static let robo = CharacterAppearance(
        id: "robo", name: ["en": "Robo", "tr": "Robo"],
        bodyColor: RGBColor(red: 52, green: 66, blue: 84), eyeShape: .square)

    public static let peach = CharacterAppearance(
        id: "peach", name: ["en": "Peach", "tr": "Şeftali"],
        bodyColor: RGBColor(red: 242, green: 163, blue: 142),
        eyeColor: RGBColor(red: 59, green: 35, blue: 32),
        blushColor: RGBColor(red: 230, green: 90, blue: 90), accessory: .bow,
        accessoryColor: RGBColor(red: 255, green: 95, blue: 132))

    public static let scholar = CharacterAppearance(
        id: "scholar", name: ["en": "Scholar", "tr": "Bilgin"],
        bodyColor: RGBColor(red: 18, green: 19, blue: 24), eyeShape: .round,
        accessory: .glasses, accessoryColor: RGBColor(red: 245, green: 190, blue: 90))

    public static let sprout = CharacterAppearance(
        id: "sprout", name: ["en": "Sprout", "tr": "Filiz"],
        bodyColor: RGBColor(red: 40, green: 92, blue: 70), accessory: .sprout,
        accessoryColor: RGBColor(red: 120, green: 210, blue: 120))

    public static let builtIns: [CharacterAppearance] = [
        .classic, .snow, .kitty, .robo, .peach, .scholar, .sprout,
    ]

    /// Loads every valid `*.json` character in `folder`. Invalid files are skipped.
    public static func load(from folder: URL) -> [CharacterAppearance] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CharacterAppearance.self, from: data)
            }
    }
}
