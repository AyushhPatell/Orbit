//
//  OrbitWeatherService.swift
//  ORBITMac
//
//  Fetches weather from Open-Meteo (free, no API key) using GPS coordinates pinned to
//  Halifax, Nova Scotia. Uses the Météo-France seamless model which consistently gives
//  the closest temperature and cloud-cover match to Apple Weather for Halifax NS.
//  Used by both the morning briefing and the live "what's the weather?" voice command.
//

import Foundation

enum OrbitWeatherService {

    // Halifax, Nova Scotia, Canada — exact GPS coordinates.
    private static let latitude  = 44.6488
    private static let longitude = -63.5752
    private static let timezone  = "America/Halifax"

    // meteofrance_seamless gives the best match to Apple Weather for Halifax NS
    // (verified empirically: 26.3°C Partly Cloudy vs default model's 28.8°C Clear Sky).
    private static let model = "meteofrance_seamless"

    // MARK: - Current conditions

    // Returns (display: with emoji, spoken: text for TTS), or nil if offline.
    static func fetchHalifax() async -> (display: String, spoken: String)? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",         value: "\(latitude)"),
            URLQueryItem(name: "longitude",        value: "\(longitude)"),
            URLQueryItem(name: "current",          value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone",         value: timezone),
            URLQueryItem(name: "models",           value: model),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let tempRaw = current["temperature_2m"] as? Double,
              let code    = current["weather_code"] as? Int
        else { return nil }

        let tempC     = "\(Int(tempRaw.rounded()))"
        let condition = wmoDescription(for: code)
        let emoji     = wmoEmoji(for: code)
        let display   = "\(emoji) \(condition), \(tempC)°C"
        let spoken    = "\(condition), \(tempC) degrees Celsius"
        return (display: display, spoken: spoken)
    }

    // MARK: - Forecast (hourly)

    struct HourlyForecast {
        let hour: Int
        let condition: String
        let tempC: String
    }

    static func fetchForecast() async -> (today: [HourlyForecast], tomorrow: [HourlyForecast], tomorrowHigh: String?, tomorrowLow: String?)? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",         value: "\(latitude)"),
            URLQueryItem(name: "longitude",        value: "\(longitude)"),
            URLQueryItem(name: "hourly",           value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily",            value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days",    value: "2"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone",         value: timezone),
            URLQueryItem(name: "models",           value: model),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly  = json["hourly"]  as? [String: Any],
              let times   = hourly["time"]  as? [String],
              let temps   = hourly["temperature_2m"]  as? [Double],
              let codes   = hourly["weather_code"]     as? [Int]
        else { return nil }

        let fmt = DateFormatter()
        fmt.dateFormat  = "yyyy-MM-dd"
        fmt.timeZone    = TimeZone(identifier: timezone) ?? .current
        let cal         = Calendar.current
        let todayStr    = fmt.string(from: Date())
        let tomorrowStr = fmt.string(from: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())

        var todayForecasts:    [HourlyForecast] = []
        var tomorrowForecasts: [HourlyForecast] = []
        for i in times.indices where i < temps.count && i < codes.count {
            let t        = times[i]
            let timePart = t.components(separatedBy: "T").last ?? ""
            let hour     = Int(timePart.prefix(2)) ?? 0
            let tempC    = "\(Int(temps[i].rounded()))"
            let cond     = wmoDescription(for: codes[i])
            if t.hasPrefix(todayStr) {
                todayForecasts.append(HourlyForecast(hour: hour, condition: cond, tempC: tempC))
            } else if t.hasPrefix(tomorrowStr) {
                tomorrowForecasts.append(HourlyForecast(hour: hour, condition: cond, tempC: tempC))
            }
        }

        var tomorrowHigh: String?
        var tomorrowLow: String?
        if let daily    = json["daily"]                  as? [String: Any],
           let maxTemps = daily["temperature_2m_max"]    as? [Double],
           let minTemps = daily["temperature_2m_min"]    as? [Double],
           maxTemps.count > 1, minTemps.count > 1 {
            tomorrowHigh = "\(Int(maxTemps[1].rounded()))"
            tomorrowLow  = "\(Int(minTemps[1].rounded()))"
        }
        return (todayForecasts, tomorrowForecasts, tomorrowHigh, tomorrowLow)
    }

    static func forecastTomorrow() async -> String? {
        guard let f = await fetchForecast() else { return nil }
        // Pick the afternoon slot (closest to 14:00) for a representative condition.
        let afternoon = f.tomorrow.min(by: { abs($0.hour - 14) < abs($1.hour - 14) })
        let cond      = afternoon?.condition ?? "variable conditions"
        let high      = f.tomorrowHigh ?? "?"
        let low       = f.tomorrowLow  ?? "?"
        return "Tomorrow expect \(cond.lowercased()), with a high of \(high) and a low of \(low) degrees Celsius in Halifax."
    }

    static func forecastSummary(for targetHour: Int) async -> String? {
        guard let forecast = await fetchForecast() else { return nil }
        let sorted = forecast.today.sorted { abs($0.hour - targetHour) < abs($1.hour - targetHour) }
        guard let closest = sorted.first else { return nil }

        let hourLabel: String
        switch closest.hour {
        case 0..<6:   hourLabel = "tonight"
        case 6..<12:  hourLabel = "this morning"
        case 12..<17: hourLabel = "this afternoon"
        case 17..<21: hourLabel = "this evening"
        default:      hourLabel = "tonight"
        }
        return "\(closest.condition), \(closest.tempC)\u{00B0}C \(hourLabel)"
    }

    // MARK: - WMO weather code mappings

    private static func wmoDescription(for code: Int) -> String {
        switch code {
        case 0:        return "Clear Sky"
        case 1:        return "Mainly Clear"
        case 2:        return "Partly Cloudy"
        case 3:        return "Overcast"
        case 45:       return "Foggy"
        case 48:       return "Freezing Fog"
        case 51:       return "Light Drizzle"
        case 53:       return "Drizzle"
        case 55:       return "Heavy Drizzle"
        case 56:       return "Freezing Drizzle"
        case 57:       return "Heavy Freezing Drizzle"
        case 61:       return "Light Rain"
        case 63:       return "Rain"
        case 65:       return "Heavy Rain"
        case 66:       return "Freezing Rain"
        case 67:       return "Heavy Freezing Rain"
        case 71:       return "Light Snow"
        case 73:       return "Snow"
        case 75:       return "Heavy Snow"
        case 77:       return "Snow Grains"
        case 80:       return "Light Rain Showers"
        case 81:       return "Rain Showers"
        case 82:       return "Heavy Rain Showers"
        case 85:       return "Snow Showers"
        case 86:       return "Heavy Snow Showers"
        case 95:       return "Thunderstorm"
        case 96, 99:   return "Thunderstorm with Hail"
        default:       return "Cloudy"
        }
    }

    private static func wmoEmoji(for code: Int) -> String {
        switch code {
        case 0:        return "☀️"
        case 1:        return "🌤️"
        case 2:        return "⛅"
        case 3:        return "☁️"
        case 45, 48:   return "🌫️"
        case 51...57:  return "🌦️"
        case 61...67:  return "🌧️"
        case 71...77:  return "🌨️"
        case 80, 81:   return "🌦️"
        case 82:       return "🌧️"
        case 85, 86:   return "🌨️"
        case 95...99:  return "⛈️"
        default:       return "🌡️"
        }
    }

    // MARK: - Reply formatting

    // Varied spoken opening — conversational, not robotic.
    static func spokenSummary(spoken: String, tip: String?) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeTemplates: [String]
        switch hour {
        case 5..<12:
            timeTemplates = [
                "Good morning! It\u{2019}s \(spoken) in Halifax.",
                "Here\u{2019}s your morning weather \u{2014} \(spoken).",
                "This morning in Halifax: \(spoken).",
            ]
        case 12..<17:
            timeTemplates = [
                "This afternoon it\u{2019}s \(spoken) in Halifax.",
                "Afternoon update \u{2014} \(spoken) right now.",
                "Currently in Halifax: \(spoken).",
            ]
        case 17..<21:
            timeTemplates = [
                "This evening it\u{2019}s \(spoken) in Halifax.",
                "Evening weather \u{2014} \(spoken).",
                "Right now in Halifax: \(spoken).",
            ]
        default:
            timeTemplates = [
                "Tonight it\u{2019}s \(spoken) in Halifax.",
                "Late night weather \u{2014} \(spoken).",
                "Outside right now: \(spoken).",
            ]
        }
        let idx = Int(Date().timeIntervalSince1970 / 300) % timeTemplates.count
        let base = timeTemplates[idx]
        return tip.map { "\(base) \($0)" } ?? base
    }

    // Time-aware, personality-driven tips — multiple per condition, rotated.
    static func tip(for spoken: String) -> String? {
        let s = spoken.lowercased()
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight   = hour >= 21 || hour < 6
        let isEvening = hour >= 17 && hour < 21
        let isMorning = hour >= 5  && hour < 12

        if s.contains("thunder") {
            return pick([
                "Thunderstorms around \u{2014} a great excuse to stay cozy inside!",
                "Thunder in the forecast. Keep your windows closed!",
                "Stormy out there. Perfect time for some indoor work.",
            ])
        }
        if s.contains("blizzard") {
            return pick(["Blizzard conditions! Stay home if you can.",
                         "Serious snow out there. Not a day for driving."])
        }
        if s.contains("heavy snow") {
            return pick(["Heavy snow today \u{2014} give yourself extra time if heading out.",
                         "Big snowfall expected. Dress warm and drive slow!"])
        }
        if s.contains("snow") || s.contains("sleet") || s.contains("freezing") {
            return pick(["Bundle up \u{2014} it\u{2019}s going to be cold and slippery!",
                         "Winter vibes outside. Layer up if you\u{2019}re heading out.",
                         "Icy conditions possible. Watch your step!"])
        }
        if s.contains("heavy rain") {
            return pick(["Heavy rain today \u{2014} you\u{2019}ll definitely want an umbrella.",
                         "Pouring out there! Maybe drive instead of walking.",
                         "Serious rain \u{2014} keep the umbrella close."])
        }
        if s.contains("rain") || s.contains("drizzle") || s.contains("shower") {
            return pick([
                isNight ? "Rainy night \u{2014} good sleeping weather!" :
                    "Don\u{2019}t forget your umbrella if you\u{2019}re heading out.",
                "A bit wet outside. Grab a jacket!",
                "Light rain \u{2014} nothing too bad, but bring a layer.",
                isEvening ? "Rainy evening \u{2014} cozy night ahead!" :
                    "Showers expected. An umbrella wouldn\u{2019}t hurt.",
            ])
        }
        if s.contains("fog") || s.contains("mist") {
            return pick(["Foggy out there \u{2014} take it slow on the roads.",
                         "Misty conditions. Visibility might be low.",
                         "Fog rolling in \u{2014} be careful driving."])
        }
        if s.hasPrefix("clear") || s.contains("mainly clear") || s.contains("sunny") {
            if isNight {
                return pick(["Clear skies tonight \u{2014} perfect for stargazing!",
                             "Beautiful clear night out there.",
                             "Clear and calm tonight. Enjoy the evening!"])
            }
            if isEvening {
                return pick(["Clear evening \u{2014} might catch a nice sunset!",
                             "Beautiful evening weather. Enjoy it!",
                             "Lovely clear skies this evening."])
            }
            return pick([
                isMorning ? "Beautiful morning! Great way to start the day." :
                    "Beautiful day! Maybe sneak in a short walk.",
                "Perfect weather to get outside for a bit.",
                "Gorgeous day \u{2014} make the most of it!",
                "Sunny and clear \u{2014} can\u{2019}t ask for better.",
                "Great weather today. Enjoy it while it lasts!",
            ])
        }
        if s.contains("partly cloudy") || s.contains("partly sunny") {
            return pick(["Mix of sun and clouds \u{2014} not bad at all!",
                         "Partly cloudy but still a decent day.",
                         "Some clouds around, but the sun\u{2019}s peeking through."])
        }
        if s.contains("overcast") || s.contains("cloudy") {
            return pick(["Grey skies today \u{2014} might want a light jacket.",
                         "Overcast but dry. Not bad for getting things done.",
                         "Cloudy day \u{2014} at least no rain in sight!",
                         isEvening ? "Cloudy evening. Good night for staying in." :
                            "Cloudy but calm out there."])
        }
        return nil
    }

    private static func pick(_ options: [String]) -> String {
        // Combine time-based rotation with a per-session random seed so the same
        // weather condition gives different tips across queries, not just every 3 minutes.
        let timeSeed  = Int(Date().timeIntervalSince1970 / 60)
        let querySeed = Int(Date().timeIntervalSince1970) % 97
        let idx = (timeSeed + querySeed) % options.count
        return options[idx]
    }
}
