import Foundation

/// Looks up a user-facing string in the app's String Catalog.
///
/// Keys are the English text. Use `String(format:)` for values instead of interpolation so
/// the key stays a plain literal that `Scripts/check-localizations.py` can find.
// swift-format-ignore: AlwaysUseLowerCamelCase
func L(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
    String(localized: key, bundle: .module, comment: comment)
}

/// The user's preferred language, in English, for instructing models ("Turkish").
var preferredLanguageName: String {
    let code =
        Locale.preferredLanguages.first.map { Locale(identifier: $0) }?.language
        .languageCode?.identifier ?? "en"
    return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
}
