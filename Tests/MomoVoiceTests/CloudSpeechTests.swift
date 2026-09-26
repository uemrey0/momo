import Foundation
import Testing

@testable import MomoVoice

@Suite("OpenAI speech")
struct OpenAISpeechTests {
    func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    @Test("asks for streamed PCM in the chosen voice")
    func request() throws {
        let speech = OpenAISpeechRequest(apiKey: "sk", voice: "nova", instructions: "Warm.")
        let request = try speech.urlRequest(for: "Merhaba!")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk")
        let json = try body(request)
        #expect(json["model"] as? String == "gpt-4o-mini-tts")
        #expect(json["voice"] as? String == "nova")
        #expect(json["input"] as? String == "Merhaba!")
        #expect(json["response_format"] as? String == "pcm")
        #expect(json["instructions"] as? String == "Warm.")
    }

    @Test("leaves out instructions for models that ignore them")
    func noInstructions() throws {
        let speech = OpenAISpeechRequest(apiKey: "sk", model: "tts-1", instructions: "Warm.")
        #expect(try body(try speech.urlRequest(for: "Hi"))["instructions"] == nil)
        #expect(OpenAISpeechRequest.voices.contains(OpenAISpeechRequest.defaultVoice))
    }
}
