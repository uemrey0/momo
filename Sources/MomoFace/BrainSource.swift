/// Where Momo's current thinking happens. The character shows it through its eye colour.
public enum BrainSource: String, CaseIterable, Sendable, Codable, Identifiable {
    /// An on-device model. White eyes.
    case local
    /// The user's own plan through an official CLI (ChatGPT, Gemini). Lavender eyes.
    case subscription
    /// A provider API key supplied by the user. Amber eyes.
    case apiKey

    public var id: String { rawValue }

    /// Eye colour as 0...255 RGB components.
    public var eyeColor: (red: Double, green: Double, blue: Double) {
        switch self {
        case .local: (245, 246, 250)
        case .subscription: (198, 192, 255)
        case .apiKey: (255, 212, 158)
        }
    }
}
