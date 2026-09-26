import Foundation
import Testing

@testable import MomoKit

@Suite("OpenMeteo")
struct WeatherTests {
    static let forecastJSON = Data(
        """
        {"latitude":41.0,"longitude":28.9375,"timezone":"Europe/Istanbul",
        "current_units":{"time":"iso8601","temperature_2m":"°C","wind_speed_10m":"km/h"},
        "current":{"time":"2026-09-26T15:45","interval":900,"temperature_2m":23.6,
        "apparent_temperature":21.6,"relative_humidity_2m":58,"weather_code":1,
        "wind_speed_10m":25.2,"is_day":1},
        "daily_units":{"temperature_2m_max":"°C"},
        "daily":{"time":["2026-09-26","2026-09-27"],"weather_code":[3,80],
        "temperature_2m_max":[24.1,20.5],"temperature_2m_min":[18.1,18.0],
        "precipitation_probability_max":[0,null],"sunrise":["2026-09-26T06:55","2026-09-27T06:56"],
        "sunset":["2026-09-26T18:55","2026-09-27T18:53"]}}
        """.utf8)

    static let placesJSON = Data(
        """
        {"results":[
        {"id":2988507,"name":"Paris","latitude":48.85341,"longitude":2.3488,"country_code":"FR",
        "timezone":"Europe/Paris","country":"France","admin1":"Île-de-France Region"},
        {"id":4717560,"name":"Paris","latitude":33.66094,"longitude":-95.55551,"country_code":"US",
        "timezone":"America/Chicago","country":"United States","admin1":"Texas"}]}
        """.utf8)

    @Test("parses current conditions and daily forecasts")
    func parsesForecast() throws {
        let forecast = try OpenMeteo.parseForecast(Self.forecastJSON)
        #expect(forecast.current?.temperature == 23.6)
        #expect(forecast.current?.weatherCode == 1)
        #expect(forecast.current?.isDay == true)
        #expect(forecast.days.count == 2)
        #expect(forecast.days[1].weatherCode == 80)
        #expect(forecast.days[1].precipitationProbability == nil)
        #expect(forecast.temperatureUnit == "°C")
        #expect(forecast.timezone == "Europe/Istanbul")
    }

    @Test("summarises the forecast for a model")
    func summary() throws {
        let forecast = try OpenMeteo.parseForecast(Self.forecastJSON)
        let place = OpenMeteo.Place(
            name: "Istanbul", latitude: 41, longitude: 29, country: "Türkiye",
            admin1: "Istanbul")
        let text = OpenMeteo.summary(place: place, forecast: forecast)
        #expect(text.hasPrefix("Weather for Istanbul, Türkiye:"))
        #expect(
            text.contains(
                "Now: 24°C, mainly clear, feels like 22°C, humidity 58%, wind 25 km/h"))
        #expect(
            text.contains(
                "2026-09-26: overcast, 18–24°C, 0% chance of precipitation, sunrise 06:55, sunset 18:55"
            ))
        #expect(text.contains("2026-09-27: light rain showers, 18–21°C, sunrise"))
    }

    @Test("parses places and picks the one matching a hint")
    func places() throws {
        let places = try OpenMeteo.parsePlaces(Self.placesJSON)
        #expect(places.count == 2)
        #expect(places[0].countryCode == "FR")
        #expect(OpenMeteo.bestPlace(in: places, hint: nil)?.country == "France")
        #expect(OpenMeteo.bestPlace(in: places, hint: "Texas")?.country == "United States")
        #expect(OpenMeteo.bestPlace(in: places, hint: "us")?.admin1 == "Texas")
        #expect(OpenMeteo.bestPlace(in: places, hint: "Mars")?.country == "France")
        #expect(try OpenMeteo.parsePlaces(Data(#"{"generationtime_ms":0.5}"#.utf8)).isEmpty)
    }

    @Test("builds requests")
    func requests() throws {
        let geocoding = try #require(OpenMeteo.geocodingURL(for: "Paris, France"))
        #expect(geocoding.absoluteString.contains("name=Paris&"))
        let forecast = try #require(
            OpenMeteo.forecastURL(latitude: 41.0082, longitude: 28.9784, days: 3))
        #expect(forecast.host == "api.open-meteo.com")
        #expect(forecast.absoluteString.contains("latitude=41.0082"))
        #expect(forecast.absoluteString.contains("forecast_days=3"))
        #expect(!forecast.absoluteString.contains("fahrenheit"))
        let imperial = try #require(
            OpenMeteo.forecastURL(latitude: 0, longitude: 0, days: 1, fahrenheit: true))
        #expect(imperial.absoluteString.contains("temperature_unit=fahrenheit"))
    }

    @Test("splits a query into a name and a hint")
    func splits() {
        #expect(OpenMeteo.splitQuery("Paris, France") == ("Paris", "France"))
        #expect(OpenMeteo.splitQuery(" Ankara ") == ("Ankara", nil))
    }

    @Test("describes weather codes")
    func codes() {
        #expect(OpenMeteo.describe(code: 0) == "clear sky")
        #expect(OpenMeteo.describe(code: 95) == "thunderstorm")
        #expect(OpenMeteo.describe(code: 1234) == "unknown conditions")
    }
}

@Suite("TimeZoneCity")
struct TimeZoneCityTests {
    @Test(
        "turns time zones into cities",
        arguments: [
            ("Europe/Istanbul", "Istanbul"), ("America/New_York", "New York"),
            ("America/Argentina/Buenos_Aires", "Buenos Aires"), ("Asia/Tokyo", "Tokyo"),
        ])
    func cities(_ identifier: String, city: String) {
        #expect(TimeZoneCity.city(fromIdentifier: identifier) == city)
    }

    @Test("ignores zones without a place", arguments: ["UTC", "GMT", "Etc/GMT+3", ""])
    func noCity(_ identifier: String) {
        #expect(TimeZoneCity.city(fromIdentifier: identifier) == nil)
    }
}
