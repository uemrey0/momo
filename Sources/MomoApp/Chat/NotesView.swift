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

/// A searchable board of notes with an inline editor.
struct NotesView: View {
    @Bindable var model: NotesModel
    @State private var searchHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ZStack {
            if let note = model.editing {
                NoteEditor(note: note, save: save, cancel: cancel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .preference(key: PanelHeightKey.self, value: 420)
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .preference(
                        key: PanelHeightKey.self, value: max(240, searchHeight + contentHeight))
            }
        }
        .animation(Theme.spring, value: model.editing?.id)
    }

    private func save(_ note: Note) {
        withAnimation(Theme.spring) { model.save(note) }
    }

    private func cancel() {
        withAnimation(Theme.spring) { model.editing = nil }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    PanelTextField(text: $model.query, placeholder: L("Search notes"))
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.card, in: Capsule())
                Button {
                    withAnimation(Theme.spring) { model.newNote() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .background(Theme.userBubble, in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("New note"))
                .accessibilityLabel(L("New note"))
            }
            .padding(12)
            .measureHeight($searchHeight)
            if model.filtered.isEmpty {
                EmptyHint(
                    systemImage: model.notes.isEmpty ? "note.text" : "magnifyingglass",
                    text: model.notes.isEmpty
                        ? L("No notes yet. Write one, or tell me “note that…” in the chat.")
                        : L("No notes match your search.")
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .measureHeight($contentHeight)
                Spacer(minLength: 0)
            } else {
                PanelScroll {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        ForEach(model.filtered) { note in
                            Button {
                                withAnimation(Theme.spring) { model.editing = note }
                            } label: {
                                NoteCard(note: note)
                            }
                            .buttonStyle(.plain)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                            .contextMenu {
                                Button(L("Delete"), role: .destructive) {
                                    withAnimation(Theme.spring) { model.delete(note) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .animation(Theme.spring, value: model.filtered)
                    .measureHeight($contentHeight)
                }
            }
        }
    }
}

private struct NoteCard: View {
    var note: Note
    @State private var isHovering = false

    var body: some View {
        let color = Theme.pastel(for: note.id)
        VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(color).frame(width: 22, height: 4)
            Text(verbatim: note.title.isEmpty ? L("Untitled") : note.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(2)
            if !note.body.isEmpty {
                Text(verbatim: note.body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
            Text(note.updatedAt, format: .relative(presentation: .named))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .padding(12)
        .background(
            LinearGradient(
                colors: [color.opacity(0.18), color.opacity(0.07)], startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color.opacity(isHovering ? 0.45 : 0.12))
        )
        .scaleEffect(isHovering ? 1.02 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Theme.quickSpring) { isHovering = hovering } }
    }
}

private struct NoteEditor: View {
    @State var note: Note
    var save: (Note) -> Void
    var cancel: () -> Void

    var body: some View {
        let color = Theme.pastel(for: note.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: cancel) {
                    Label(L("Notes"), systemImage: "chevron.left")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    save(note)
                } label: {
                    Text(verbatim: L("Save"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.userBubble, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField(text: $note.title, prompt: Text(verbatim: L("Title"))) {
                    Text(verbatim: L("Title"))
                }
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                TextEditor(text: $note.body)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [color.opacity(0.16), color.opacity(0.05)], startPoint: .top,
                    endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(14)
    }
}
