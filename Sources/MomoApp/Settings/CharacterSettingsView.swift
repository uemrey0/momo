import MomoFace
import SwiftUI

/// Lets the user pick how Momo looks, with live previews.
struct CharacterSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel
    @State private var characters: [CharacterAppearance] = []

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    private var language: String? {
        Locale.preferredLanguages.first.map { Locale(identifier: $0) }?.language.languageCode?
            .identifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(characters) { character in
                        CharacterCard(
                            appearance: character, name: character.localizedName(for: language),
                            isSelected: settings.preferences.characterID == character.id
                        ) {
                            settings.preferences.characterID = character.id
                            model.applyPreferences()
                        }
                    }
                }
                .padding(20)
            }
            HStack {
                Text(verbatim: L("Make your own character with a small JSON file."))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Open Characters Folder")) {
                    let folder = AppModel.charactersFolder
                    try? FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Button(L("Reload")) { characters = model.availableCharacters }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .onAppear { characters = model.availableCharacters }
    }
}

private struct CharacterCard: View {
    var appearance: CharacterAppearance
    var name: String
    var isSelected: Bool
    var select: () -> Void
    @State private var engine = FaceEngine()

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                FaceView(
                    engine: engine, layout: FaceLayout(topInset: 0, capWidth: 0, scale: 0.55),
                    appearance: appearance
                )
                .frame(height: 80)
                .clipped()
                .allowsHitTesting(false)
                Text(verbatim: name).font(.callout.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.78, green: 0.83, blue: 0.9),
                            Color(red: 0.88, green: 0.84, blue: 0.86),
                        ],
                        startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )
            .foregroundStyle(.black.opacity(0.8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear { engine.sleepDelay = .infinity }
    }
}
