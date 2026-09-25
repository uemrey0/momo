import MomoKit
import SwiftUI

/// Mirrors the store's notes for the Notes tab.
@MainActor
@Observable
final class NotesModel {
    private(set) var notes: [Note] = []
    var query = ""
    var editing: Note?

    let store: MomoStore
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(store: MomoStore) {
        self.store = store
        observation = Task { [weak self] in
            for await data in await store.changes() {
                self?.notes = data.notes.sorted { $0.updatedAt > $1.updatedAt }
            }
        }
    }

    var filtered: [Note] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return notes }
        return notes.filter { note in
            let text = (note.title + " " + note.body).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    func newNote() {
        editing = Note(title: "", body: "")
    }

    func save(_ note: Note) {
        editing = nil
        var note = note
        note.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.title.isEmpty || !note.body.isEmpty else { return }
        if note.title.isEmpty {
            note.title = String(note.body.prefix(40))
        }
        Task { try? await store.saveNote(note) }
    }

    func delete(_ note: Note) {
        if editing?.id == note.id { editing = nil }
        Task { try? await store.deleteNote(note.id) }
    }
}

/// A searchable list of notes with an inline editor.
struct NotesView: View {
    @Bindable var model: NotesModel

    var body: some View {
        if let note = model.editing {
            NoteEditor(note: note, save: model.save, cancel: { model.editing = nil })
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    PanelTextField(text: $model.query, placeholder: L("Search notes"))
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                IconButton(systemImage: "square.and.pencil", help: L("New note")) {
                    model.newNote()
                }
            }
            .padding(12)
            if model.filtered.isEmpty {
                Spacer()
                EmptyHint(
                    text: model.notes.isEmpty
                        ? L("No notes yet. Write one, or tell me “note that…” in the chat.")
                        : L("No notes match your search."))
                Spacer()
            } else {
                PanelScroll {
                    LazyVStack(spacing: 8) {
                        ForEach(model.filtered) { note in
                            Button {
                                model.editing = note
                            } label: {
                                NoteCard(note: note)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(L("Delete"), role: .destructive) { model.delete(note) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct NoteCard: View {
    var note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: note.title.isEmpty ? L("Untitled") : note.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if !note.body.isEmpty {
                Text(verbatim: note.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            Text(note.updatedAt, format: .relative(presentation: .named))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

private struct NoteEditor: View {
    @State var note: Note
    var save: (Note) -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L("Cancel"), action: cancel).buttonStyle(.borderless)
                Spacer()
                Button(L("Save")) { save(note) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .controlSize(.small)
            TextField(text: $note.title, prompt: Text(verbatim: L("Title"))) {
                Text(verbatim: L("Title"))
            }
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            TextEditor(text: $note.body)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
    }
}
