import Foundation
import NaturalLanguage
import Testing

@testable import MomoKit

@Suite("Memory ranking")
struct MemoryRankerTests {
    let keywords = MemoryRanker(usesEmbeddings: false)

    @Test("folds case, diacritics and Turkish dotted and dotless i")
    func tokens() {
        #expect(
            MemoryRanker.tokens("İstanbul'da KAHVEYİ ılık içer") == [
                "istanbul", "kahveyi", "ilik", "icer",
            ])
        #expect(MemoryRanker.tokens("The user's sister is Ayşe") == ["sister", "ayse"])
    }

    @Test("matches stems loosely")
    func stems() {
        #expect(MemoryRanker.wordMatch("kahve", "kahveyi") == 0.8)
        #expect(MemoryRanker.wordMatch("kitap", "kitabi") == 0.6)
        #expect(MemoryRanker.wordMatch("running", "running") == 1)
        #expect(MemoryRanker.wordMatch("car", "carpet") == 0)
        #expect(MemoryRanker.wordMatch("anne", "annem") == 0.8)
    }

    @Test("keyword ranking is deterministic and prefers related memories")
    func keywordRanking() {
        let memories = [
            Memory(text: "The user drinks coffee without sugar"),
            Memory(text: "Ayşe is the user's sister"),
            Memory(text: "The user is working on a Swift app called Momo"),
            Memory(text: "Kullanıcı kahveyi sütsüz içer"),
        ]
        let english = keywords.rank(memories, by: \.text, query: "Make me a coffee order")
        #expect(english.first?.item.text == "The user drinks coffee without sugar")
        let turkish = keywords.rank(memories, by: \.text, query: "Kahve ısmarlar mısın?")
        #expect(turkish.first?.item.text == "Kullanıcı kahveyi sütsüz içer")
        let swift = keywords.rank(memories, by: \.text, query: "How is my momo app going?")
        #expect(swift.first?.item.text.contains("Momo") == true)
        #expect(keywords.rank(memories, by: \.text, query: "hello").allSatisfy { $0.score == 0 })
    }

    @Test("ties go to the most recent memory")
    func ties() {
        let memories = [Memory(text: "Alpha"), Memory(text: "Beta")]
        #expect(keywords.rank(memories, by: \.text, query: "zzz").first?.item.text == "Beta")
    }

    @Test("keeps every memory when they all fit")
    func allFit() {
        let memories = (0..<5).map { Memory(text: "Fact \($0)") }
        #expect(keywords.promptMemories(from: memories, message: "hi") == memories)
    }

    @Test("puts recent core memories first, then related ones, within the limit")
    func promptSelection() {
        var memories = (0..<30).map { Memory(text: "Unrelated fact number \($0)") }
        memories.insert(Memory(text: "Prefers short answers", category: .preference), at: 3)
        memories.insert(Memory(text: "Ayşe is the user's sister", category: .person), at: 10)
        memories.append(Memory(text: "The user's dentist appointment is on Friday"))
        let selected = keywords.promptMemories(
            from: memories, message: "When is my dentist appointment?", coreLimit: 5, limit: 6)
        #expect(selected.count == 6)
        #expect(selected[0].text == "Prefers short answers")
        #expect(selected[1].text == "Ayşe is the user's sister")
        #expect(selected[2].text == "The user's dentist appointment is on Friday")
    }

    @Test("search_notes falls back to related notes when none has every word")
    func noteSearch() async throws {
        let store = temporaryStore()
        try await store.addNote(title: "Kahve tarifi", body: "Filtre kahve, 15 gram")
        try await store.addNote(title: "Groceries", body: "Milk, eggs")
        let box = Toolbox(StoreTools.all(store: store))
        let result = await box.execute(
            ToolCall(
                id: "1", name: "search_notes", arguments: #"{"query":"kahveyi nasıl yapıyorum"}"#))
        #expect(result.output.contains("Kahve tarifi"))
        #expect(!result.output.contains("Groceries"))
        let none = await box.execute(
            ToolCall(id: "2", name: "search_notes", arguments: #"{"query":"bicycle"}"#))
        #expect(none.output == "No notes found.")
    }

    @Test("sentence embeddings find related memories without shared words")
    func embeddings() throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else { return }
        let ranker = MemoryRanker()
        let memories = [
            Memory(text: "The user loves pizza and Italian pasta"),
            Memory(text: "The user's laptop is a silver MacBook Pro"),
        ]
        // The older memory must win on meaning alone: the words don't overlap.
        let ranked = ranker.rank(memories, by: \.text, query: "What should I eat for dinner?")
        #expect(ranked.first?.item.text == "The user loves pizza and Italian pasta")
    }
}
