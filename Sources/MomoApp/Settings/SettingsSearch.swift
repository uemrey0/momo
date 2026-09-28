import MomoKit
import SwiftUI

/// One setting that Settings search can find.
struct SearchableSetting: Identifiable, Hashable {
    var pane: SettingsPane
    /// The setting's label, as the pane shows it.
    var title: String
    /// Other words people might search for, comma-separated.
    var keywords = ""
    /// The setting's ``View/settingsAnchor(_:)`` id; `nil` opens the pane at the top.
    var anchor: String?

    var id: String { pane.rawValue + "/" + title }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return title.range(of: query, options: options) != nil
            || keywords.range(of: query, options: options) != nil
    }
}

/// Every setting search can find. Add an entry, with an anchor on the view, when you add a
/// setting; a test checks that titles are unique within a pane and anchors across panes.
enum SettingsSearch {
    static var all: [SearchableSetting] {
        ai + abilities + voice + meetings + routines + character + reactions + connections
            + permissions + privacy + general + about
    }

    /// The settings matching `query`, grouped by pane in sidebar order.
    static func results(for query: String) -> [SearchableSetting] {
        all.filter { $0.matches(query) }
    }

    private static var ai: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .ai, title: L("Connect a brain"),
                keywords: L(
                    "ChatGPT, Codex, Gemini, Claude, OpenAI, OpenRouter, Ollama, LM Studio, Apple Intelligence, API key, subscription"
                )),
            SearchableSetting(
                pane: .ai, title: L("Advanced: order, models and routing"),
                keywords: L("remote brain, ask before, difficulty, model, order, routing"),
                anchor: "ai.advanced"),
        ]
    }

    private static var abilities: [SearchableSetting] {
        ToolGroup.visible.map { group in
            SearchableSetting(
                pane: .abilities, title: group.title, keywords: group.summary,
                anchor: "abilities." + group.id)
        } + [
            SearchableSetting(
                pane: .abilities, title: L("Draw with"),
                keywords: L("draw, image, picture, Image Playground, OpenAI, Gemini, ChatGPT"),
                anchor: "abilities.images.backend")
        ]
    }

    // Voice has no anchors yet, so its results open the pane at the top.
    private static var voice: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .voice, title: L("Voice models"),
                keywords: L(
                    "voice, speech model, Kokoro, Supertonic, Nemotron, download, add model")),
            SearchableSetting(pane: .voice, title: L("Test Voice")),
            SearchableSetting(
                pane: .voice, title: L("Read every reply aloud"),
                keywords: L("speak, read aloud, voice replies")),
            SearchableSetting(
                pane: .voice, title: L("Voices"),
                keywords: L("Momo's voice models, OpenAI voices, sound")),
            SearchableSetting(
                pane: .voice, title: L("Hold the shortcut to talk"),
                keywords: L("push to talk, shortcut, talk to Momo")),
            SearchableSetting(pane: .voice, title: L("Open the chat for spoken requests")),
            SearchableSetting(
                pane: .voice, title: L("Live conversation"),
                keywords: L("engine, interrupt, follow-up, realtime, OpenAI Realtime, Gemini Live")),
            SearchableSetting(
                pane: .voice, title: L("Cloud realtime voice"),
                keywords: L("speech to speech, OpenAI Realtime, Gemini Live, cloud voice")),
            SearchableSetting(
                pane: .voice, title: L("Speech recognition"),
                keywords: L("dictation, transcription, Whisper, microphone")),
            SearchableSetting(
                pane: .voice, title: L("Listen for “Hey Momo”"), keywords: L("wake word")),
        ]
    }

    private static var meetings: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .meetings, title: L("Offer to take meeting notes"),
                keywords: L("record, transcript, summary, Zoom, Teams, Meet"),
                anchor: "meetings.offer"),
            SearchableSetting(
                pane: .meetings, title: L("Meeting language"), anchor: "meetings.language"),
            SearchableSetting(
                pane: .meetings, title: L("Keep meeting audio"), keywords: L("WAV, recording"),
                anchor: "meetings.audio"),
            SearchableSetting(
                pane: .meetings, title: L("Call audio"),
                keywords: L("screen recording, system audio"), anchor: "meetings.callAudio"),
        ]
    }

    private static var routines: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .routines, title: L("Add Routine…"),
                keywords: L("schedule, every day, morning brief, recurring"),
                anchor: "routines.add")
        ]
    }

    private static var character: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .character, title: L("Personality"),
                keywords: L("tone, cheerful, calm, witty, professional"),
                anchor: "character.personality"),
            SearchableSetting(
                pane: .character, title: L("Open Characters Folder"),
                keywords: L("custom character, JSON, look, skin"), anchor: "character.custom"),
        ]
    }

    private static var reactions: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .reactions, title: L("Remind me before meetings"),
                keywords: L("calendar, events"), anchor: "reactions.calendar"),
            SearchableSetting(
                pane: .reactions, title: L("Dance along when music plays"),
                anchor: "reactions.music"),
            SearchableSetting(
                pane: .reactions, title: L("Worry when the battery is low"),
                anchor: "reactions.battery"),
            SearchableSetting(
                pane: .reactions, title: L("Yawn when it gets very late"),
                anchor: "reactions.lateNight"),
            SearchableSetting(
                pane: .reactions, title: L("Doze off after"), keywords: L("sleep, asleep, idle"),
                anchor: "reactions.sleep"),
        ]
    }

    private static var connections: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .connections, title: L("Use Momo from Claude, Codex and other agents"),
                keywords: L("MCP, Claude Code, Claude Desktop, Cursor"),
                anchor: "connections.agents"),
            SearchableSetting(
                pane: .connections, title: L("MCP servers Momo can use"),
                keywords: L("add server, tools, command"), anchor: "connections.servers"),
            SearchableSetting(
                pane: .connections, title: L("Brave Search API key"),
                keywords: L("web search, DuckDuckGo"), anchor: "connections.webSearch"),
        ]
    }

    private static var permissions: [SearchableSetting] {
        PermissionCenter.basics.map { permission in
            SearchableSetting(
                pane: .permissions, title: permission.title, keywords: permission.purpose,
                anchor: permission.anchor)
        } + [
            SearchableSetting(
                pane: .permissions, title: L("Automation"),
                keywords: L(
                    "Mail, Messages, Music, Spotify, System Events, Safari, Chrome, Arc, Edge, Brave"
                ))
        ]
    }

    private static var privacy: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .privacy, title: L("Keep everything on this Mac"),
                keywords: L("local only, offline"), anchor: "privacy.localOnly"),
            SearchableSetting(
                pane: .privacy, title: L("Hide personal details from remote brains"),
                keywords: L("mask, email, phone, IBAN, names"), anchor: "privacy.masking"),
            SearchableSetting(
                pane: .privacy, title: L("Screen, selected text and other access"),
                anchor: "privacy.permissions"),
            SearchableSetting(
                pane: .privacy, title: L("Hide Momo from screen recordings and sharing"),
                keywords: L("screenshot, screen sharing"), anchor: "privacy.captureHiding"),
            SearchableSetting(
                pane: .privacy, title: L("Sent to remote brains"),
                keywords: L("log, outbound, history"), anchor: "privacy.log"),
            SearchableSetting(
                pane: .privacy, title: L("Erase all of Momo's data…"),
                keywords: L("delete, reset"), anchor: "privacy.erase"),
        ]
    }

    private static var general: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .general, title: L("Open Momo"), keywords: L("shortcut, hotkey"),
                anchor: "general.shortcut"),
            SearchableSetting(
                pane: .general, title: L("Open at login"), keywords: L("startup, launch"),
                anchor: "general.login"),
            SearchableSetting(
                pane: .general, title: L("Check for updates automatically"),
                keywords: L("update, new version"), anchor: "general.updates"),
            SearchableSetting(
                pane: .general, title: L("Show the welcome tour again"),
                keywords: L("onboarding, introduction"), anchor: "general.tour"),
        ]
    }

    private static var about: [SearchableSetting] {
        [
            SearchableSetting(
                pane: .about, title: L("Report a problem"), keywords: L("bug, issue")),
            SearchableSetting(pane: .about, title: L("Website"), keywords: L("GitHub, license")),
        ]
    }
}

/// A search result in the sidebar: the setting, and the pane it's in.
struct SearchResultLabel: View {
    var setting: SearchableSetting

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: setting.pane.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(setting.pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: setting.title).lineLimit(1)
                Text(verbatim: setting.pane.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
