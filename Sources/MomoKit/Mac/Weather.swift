import Foundation

/// Requests and parsing for the free Open-Meteo weather and geocoding APIs, which need no key.
public enum OpenMeteo {
    /// A place found by the geocoding API.
    public struct Place: Sendable, Equatable, Decodable {
        public var name: String
        public var latitude: Double
        public var longitude: Double
        public var country: String?
        public var countryCode: String?
        public var admin1: String?
        public var timezone: String?

        public init(
            name: String, latitude: Double, longitude: Double, country: String? = nil,
            countryCode: String? = nil, admin1: String? = nil, timezone: String? = nil
        ) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.country = country
            self.countryCode = countryCode
            self.admin1 = admin1
            self.timezone = timezone
        }

        enum CodingKeys: String, CodingKey {
            case name, latitude, longitude, country, admin1, timezone
            case countryCode = "country_code"
        }

        /// "Istanbul, Istanbul, Türkiye" without repeated parts.
        public var displayName: String {
            var parts = [name]
            for part in [admin1, country] {
                if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
            }
            return parts.joined(separator: ", ")
        }
    }

    /// The weather now.
    public struct Current: Sendable, Equatable {
        public var time: String
        public var temperature: Double
        public var apparentTemperature: Double?
        public var humidity: Double?
        public var windSpeed: Double?
        public var weatherCode: Int
        public var isDay: Bool
    }

    /// The forecast for one day.
    public struct Day: Sendable, Equatable {
        /// `yyyy-MM-dd` in the place's time zone.
        public var date: String
        public var weatherCode: Int
        public var maxTemperature: Double
        public var minTemperature: Double
        public var precipitationProbability: Double?
        public var sunrise: String?
        public var sunset: String?
    }

    /// A forecast with the units the API used.
    public struct Forecast: Sendable, Equatable {
        public var current: Current?
        public var days: [Day]
        public var temperatureUnit: String
        public var windSpeedUnit: String
        public var timezone: String?
    }

    /// The geocoding request for a place name. Only the part before the first comma is
    /// searched; the API does not understand "Paris, France".
    public static func geocodingURL(for query: String, language: String = "en") -> URL? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: splitQuery(query).name),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// The forecast request: current conditions plus `days` daily forecasts.
    public static func forecastURL(
        latitude: Double, longitude: Double, days: Int, fahrenheit: Bool = false
    ) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        var items = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(
                name: "current",
                value:
                    "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
            ),
            URLQueryItem(
                name: "daily",
                value:
                    "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"
            ),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(min(16, max(1, days)))),
        ]
        if fahrenheit {
            items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit"))
            items.append(URLQueryItem(name: "wind_speed_unit", value: "mph"))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Splits "Paris, France" into the name to search and a hint to pick the right result.
    public static func splitQuery(_ query: String) -> (name: String, hint: String?) {
        let parts = query.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let name = parts.first ?? ""
        let hint = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (name, hint)
    }

    /// Reads the places from a geocoding response. No match gives an empty list.
    public static func parsePlaces(_ data: Data) throws -> [Place] {
        struct Response: Decodable { var results: [Place]? }
        return try JSONDecoder().decode(Response.self, from: data).results ?? []
    }

    /// Picks the place that matches the hint ("France", "FR", "Texas"), or the first one.
    public static func bestPlace(in places: [Place], hint: String?) -> Place? {
        guard let hint = hint?.lowercased(), !hint.isEmpty else { return places.first }
        let match = places.first { place in
            [place.country, place.countryCode, place.admin1].contains {
                guard let value = $0?.lowercased() else { return false }
                return value == hint || value.hasPrefix(hint)
            }
        }
        return match ?? places.first
    }

    /// Reads a forecast response.
    public static func parseForecast(_ data: Data) throws -> Forecast {
        let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
        var current: Current?
        if let value = response.current, let temperature = value.temperature_2m {
            current = Current(
                time: value.time ?? "", temperature: temperature,
                apparentTemperature: value.apparent_temperature,
                humidity: value.relative_humidity_2m, windSpeed: value.wind_speed_10m,
                weatherCode: value.weather_code ?? 0, isDay: (value.is_day ?? 1) == 1)
        }
        var days: [Day] = []
        if let daily = response.daily {
            for (index, date) in daily.time.enumerated() {
                guard let high = daily.temperature_2m_max?[safe: index] ?? nil,
                    let low = daily.temperature_2m_min?[safe: index] ?? nil
                else { continue }
                days.append(
                    Day(
                        date: date, weatherCode: (daily.weather_code?[safe: index] ?? nil) ?? 0,
                        maxTemperature: high, minTemperature: low,
                        precipitationProbability: daily.precipitation_probability_max?[
                            safe: index] ?? nil,
                        sunrise: daily.sunrise?[safe: index] ?? nil,
                        sunset: daily.sunset?[safe: index] ?? nil))
            }
        }
        return Forecast(
            current: current, days: days,
            temperatureUnit: response.current_units?.temperature_2m
                ?? response.daily_units?.temperature_2m_max ?? "°C",
            windSpeedUnit: response.current_units?.wind_speed_10m ?? "km/h",
            timezone: response.timezone)
    }

    /// Describes a WMO weather code in English, e.g. 61 → "light rain".
    public static func describe(code: Int) -> String {
        switch code {
        case 0: "clear sky"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51: "light drizzle"
        case 53: "drizzle"
        case 55: "heavy drizzle"
        case 56, 57: "freezing drizzle"
        case 61: "light rain"
        case 63: "rain"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71: "light snow"
        case 73: "snow"
        case 75: "heavy snow"
        case 77: "snow grains"
        case 80: "light rain showers"
        case 81: "rain showers"
        case 82: "violent rain showers"
        case 85: "light snow showers"
        case 86: "heavy snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "unknown conditions"
        }
    }

    /// A compact summary for a model.
    public static func summary(place: Place, forecast: Forecast) -> String {
        let unit = forecast.temperatureUnit
        var lines = ["Weather for \(place.displayName):"]
        if let now = forecast.current {
            var line =
                "Now: \(format(now.temperature))\(unit), \(describe(code: now.weatherCode))"
            if let feels = now.apparentTemperature {
                line += ", feels like \(format(feels))\(unit)"
            }
            if let humidity = now.humidity { line += ", humidity \(format(humidity))%" }
            if let wind = now.windSpeed {
                line += ", wind \(format(wind)) \(forecast.windSpeedUnit)"
            }
            if !now.isDay { line += " (night)" }
            lines.append(line)
        }
        for day in forecast.days {
            var line =
                "\(day.date): \(describe(code: day.weatherCode)), \(format(day.minTemperature))–\(format(day.maxTemperature))\(unit)"
            if let rain = day.precipitationProbability {
                line += ", \(format(rain))% chance of precipitation"
            }
            if let sunrise = day.sunrise, let sunset = day.sunset {
                line += ", sunrise \(timeOfDay(sunrise)), sunset \(timeOfDay(sunset))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// "2026-09-26T06:58" → "06:58"
    private static func timeOfDay(_ value: String) -> String {
        value.split(separator: "T").last.map(String.init) ?? value
    }

    // swift-format-ignore: AlwaysUseLowerCamelCase
    private struct ForecastResponse: Decodable {
        struct CurrentValues: Decodable {
            var time: String?
            var temperature_2m: Double?
            var apparent_temperature: Double?
            var relative_humidity_2m: Double?
            var wind_speed_10m: Double?
            var weather_code: Int?
            var is_day: Int?
        }
        struct Units: Decodable {
            var temperature_2m: String?
            var temperature_2m_max: String?
            var wind_speed_10m: String?
        }
        struct Daily: Decodable {
            var time: [String]
            var weather_code: [Int?]?
            var temperature_2m_max: [Double?]?
            var temperature_2m_min: [Double?]?
            var precipitation_probability_max: [Double?]?
            var sunrise: [String?]?
            var sunset: [String?]?
        }
        var timezone: String?
        var current: CurrentValues?
        var current_units: Units?
        var daily: Daily?
        var daily_units: Units?
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Guesses the user's city from their time zone, for a default weather location.
public enum TimeZoneCity {
    /// "Europe/Istanbul" → "Istanbul", "America/Argentina/Buenos_Aires" → "Buenos Aires".
    /// Returns `nil` for zones that are not named after a place, such as "UTC" or "Etc/GMT+3".
    public static func city(fromIdentifier identifier: String) -> String? {
        let parts = identifier.split(separator: "/")
        guard parts.count >= 2, parts.first != "Etc", let last = parts.last else { return nil }
        let city = last.replacingOccurrences(of: "_", with: " ")
        return city.isEmpty ? nil : city
    }

    /// The city for a time zone, see ``city(fromIdentifier:)``.
    public static func city(for timeZone: TimeZone = .current) -> String? {
        city(fromIdentifier: timeZone.identifier)
    }
}
