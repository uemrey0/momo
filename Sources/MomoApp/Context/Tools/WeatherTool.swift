import Foundation
import MomoKit

/// The weather from Open-Meteo, which needs no account or key. Without a place, Momo uses the
/// city of the Mac's time zone, so no location permission is needed.
enum WeatherTool {
    static func all() -> [any MomoTool] {
        [weather()]
    }

    static func weather() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "get_weather",
                description:
                    "Get the current weather and the daily forecast for a place. Without a location it uses the user's city from their time zone; mention which place you used.",
                parameters: JSONSchema.object([
                    "location": JSONSchema.string(
                        "City, optionally with country or region, e.g. “Paris, France”"),
                    "days": JSONSchema.integer("Days of forecast, 1 (today) to 7; default 1"),
                ]),
                activityLabel: L("Checking the weather"))
        ) { arguments in
            let requested = arguments["location"]?.stringValue?
                .trimmingCharacters(in: .whitespaces)
            guard
                let query = (requested?.isEmpty == false ? requested : nil)
                    ?? TimeZoneCity.city()
            else {
                throw ToolError("I don't know where the user is. Ask for a city.")
            }
            let place = try await findPlace(query)
            let days = min(7, max(1, arguments["days"]?.intValue ?? 1))
            let fahrenheit = Locale.current.measurementSystem == .us
            guard
                let url = OpenMeteo.forecastURL(
                    latitude: place.latitude, longitude: place.longitude, days: days,
                    fahrenheit: fahrenheit)
            else { throw ToolError("I couldn't build the weather request.") }
            let forecast = try OpenMeteo.parseForecast(try await fetch(url))
            return OpenMeteo.summary(place: place, forecast: forecast)
        }
    }

    private static func findPlace(_ query: String) async throws -> OpenMeteo.Place {
        guard let url = OpenMeteo.geocodingURL(for: query) else {
            throw ToolError("I couldn't look up that place.")
        }
        let places = try OpenMeteo.parsePlaces(try await fetch(url))
        guard let place = OpenMeteo.bestPlace(in: places, hint: OpenMeteo.splitQuery(query).hint)
        else {
            throw ToolError("I couldn't find a place called “\(query)”. Try a nearby city.")
        }
        return place
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Momo (macOS assistant)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolError("The weather service is unavailable right now.")
        }
        return data
    }
}
