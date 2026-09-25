import Foundation
import Testing

@testable import MomoFace

@Suite("Character appearance")
struct CharacterAppearanceTests {
    @Test("parses hex colours")
    func hexColours() {
        #expect(RGBColor(hex: "#FF8000") == RGBColor(red: 255, green: 128, blue: 0))
        #expect(RGBColor(hex: "12ab9C")?.hex == "#12AB9C")
        #expect(RGBColor(hex: "#12345") == nil)
        #expect(RGBColor(hex: "zzzzzz") == nil)
    }

    @Test("decodes a character pack")
    func decodesPack() throws {
        let json = """
            {
              "id": "lava",
              "name": { "en": "Lava", "tr": "Lav" },
              "bodyColor": "#3A0F0A",
              "eyeColor": "#FFB36B",
              "blushColor": "#FF5A3C",
              "eyeShape": "round",
              "accessory": "freckles",
              "accessoryColor": "#FFD29B"
            }
            """
        let look = try JSONDecoder().decode(CharacterAppearance.self, from: Data(json.utf8))
        #expect(look.id == "lava")
        #expect(look.localizedName(for: "tr") == "Lav")
        #expect(look.localizedName(for: "de") == "Lava")
        #expect(look.eyeShape == .round)
        #expect(look.accessory == .freckles)
        #expect(!look.hasLightBody)
    }

    @Test("rejects invalid colours")
    func rejectsInvalidColours() {
        let json =
            ##"{"id":"x","name":{"en":"X"},"bodyColor":"red","blushColor":"#FFFFFF","eyeShape":"pill","accessory":"none"}"##
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CharacterAppearance.self, from: Data(json.utf8))
        }
    }

    @Test("loads valid packs from a folder and skips broken ones")
    func loadsFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-characters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(CharacterAppearance.peach).write(
            to: folder.appendingPathComponent("a.json"))
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("b.json"))
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("c.txt"))
        let looks = CharacterAppearance.load(from: folder)
        #expect(looks == [.peach])
    }

    @Test("built-in characters have unique IDs and names")
    func builtIns() {
        let ids = CharacterAppearance.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(
            CharacterAppearance.builtIns.allSatisfy { $0.name["en"] != nil && $0.name["tr"] != nil }
        )
        #expect(CharacterAppearance.snow.hasLightBody)
    }
}
