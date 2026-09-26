import Testing

@testable import MomoVoiceCore

@Suite("Sentence splitting and speech queueing")
struct SpeechQueueTests {
    @Test("releases a sentence as soon as the next one starts")
    func streamsSentences() {
        var chunker = SentenceChunker()
        #expect(chunker.append("Merhaba, nas") == [])
        #expect(chunker.append("ılsın? ") == [])
        #expect(chunker.append("Bugün") == ["Merhaba, nasılsın?"])
        #expect(chunker.append(" hava güzel.") == [])
        #expect(chunker.finish() == ["Bugün hava güzel."])
    }

    @Test("keeps decimals, abbreviations and Turkish ordinals together")
    func keepsNonBoundaries() {
        var chunker = SentenceChunker()
        let text = "Fiyat 3.5 lira oldu. 5. sınıfta okuyor, e.g. this works. Sonra geldi."
        var pieces = chunker.append(text)
        pieces += chunker.finish()
        #expect(
            pieces == [
                "Fiyat 3.5 lira oldu.", "5. sınıfta okuyor, e.g. this works.", "Sonra geldi.",
            ])
    }

    @Test("splits at new lines and after closing quotes")
    func newLinesAndQuotes() {
        var chunker = SentenceChunker()
        var pieces = chunker.append("He said \"yes.\" Then left\nNext line")
        pieces += chunker.finish()
        #expect(pieces == ["He said \"yes.\"", "Then left", "Next line"])
    }

    @Test("cuts long sentences at a clause or a space")
    func cutsLongSentences() {
        var chunker = SentenceChunker(maximumLength: 40, firstPieceLength: 1000)
        let text = "one two three four five six seven, eight nine ten eleven twelve thirteen"
        var pieces = chunker.append(text)
        pieces += chunker.finish()
        #expect(pieces.allSatisfy { $0.count <= 40 })
        #expect(pieces.first == "one two three four five six seven,")
        #expect(pieces.joined(separator: " ") == text)
    }

    @Test("the first piece may end at a comma to start speaking sooner")
    func earlyFirstPiece() {
        var chunker = SentenceChunker(maximumLength: 180, firstPieceLength: 20)
        #expect(
            chunker.append("Well, that is a long opening clause, and ") == [
                "Well, that is a long opening clause,"
            ])
        #expect(chunker.append("then more, and more.") == [])
        #expect(chunker.finish() == ["and then more, and more."])
    }

    @Test("drops Markdown and pieces with nothing to say")
    func cleansText() {
        var chunker = SentenceChunker()
        var pieces = chunker.append("**Tamam!** ")
        pieces += chunker.append("## Başlık\n--- \n")
        pieces += chunker.finish()
        #expect(pieces == ["Tamam!", "Başlık"])
    }

    @Test("marks the last piece of an utterance, or adds an end marker")
    func marksLastPiece() {
        var queue = SpeechQueue()
        #expect(
            queue.speak(id: "1", text: "Bir. İki", isFinal: false) == [
                SpeechPiece(utteranceID: "1", text: "Bir.", isLast: false)
            ])
        #expect(queue.isOpen("1"))
        #expect(
            queue.speak(id: "1", text: " üç.", isFinal: true) == [
                SpeechPiece(utteranceID: "1", text: "İki üç.", isLast: true)
            ])
        #expect(!queue.isOpen("1"))
        #expect(
            queue.speak(id: "2", text: "", isFinal: true) == [
                SpeechPiece(utteranceID: "2", text: nil, isLast: true)
            ])
    }

    @Test("utterances do not mix, and cancelled ones stay silent")
    func cancels() {
        var queue = SpeechQueue()
        _ = queue.speak(id: "a", text: "Birinci cümle", isFinal: false)
        #expect(queue.speak(id: "b", text: "Other. ", isFinal: false) == [])
        queue.cancelAll(alsoCancelled: ["playing"])
        #expect(queue.speak(id: "a", text: " devam.", isFinal: true) == [])
        #expect(queue.speak(id: "playing", text: "Late.", isFinal: true) == [])
        #expect(
            queue.speak(id: "c", text: "New.", isFinal: true) == [
                SpeechPiece(utteranceID: "c", text: "New.", isLast: true)
            ])
    }
}
