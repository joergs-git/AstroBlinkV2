// AIsaac — Astronomy weather and seeing forecast
// Uses 7Timer (free, no API key) for seeing/transparency/cloud cover
// and Open-Meteo (free, no API key) for general weather
import Foundation

@MainActor
class AIsaacWeatherService {
    static let shared = AIsaacWeatherService()

    // Cached forecast (refreshed every hour)
    private var cachedForecast: AstroForecast?
    private var cacheTime: Date?
    private var cachedLat: Double?
    private var cachedLon: Double?

    struct AstroForecast {
        let hours: [HourlyForecast]
        let hourlyCloud: [HourlyCloud]  // 1-hourly cloud cover from Open-Meteo
        let fetchTime: Date

        struct HourlyCloud {
            let time: Date
            let cloudCover: Int  // 0-100%
        }

        struct HourlyForecast {
            let time: Date
            let cloudCover: Int          // % (0=clear, 100=overcast)
            let seeing: Int              // 7Timer scale: 1=<0.5" (superb) to 8=>2" (bad)
            let transparency: Int        // 7Timer scale: 1=<0.3 (superb) to 8=>1 (bad)
            let windSpeed: Double?       // km/h
            let temperature: Double?     // celsius
            let humidity: Int?           // %
            let dewPoint: Double?        // celsius
        }

        // Human-readable summary for AIsaac context
        func contextSummary(timezone: TimeZone) -> String {
            var lines: [String] = ["TONIGHT'S WEATHER FORECAST (from 7Timer + Open-Meteo):"]

            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            df.timeZone = timezone

            // Filter to nighttime hours (18:00 - 06:00 local)
            let cal = Calendar.current
            let nightHours = hours.filter { hour in
                let comps = cal.dateComponents(in: timezone, from: hour.time)
                let h = comps.hour ?? 12
                return h >= 18 || h <= 6
            }

            guard !nightHours.isEmpty else {
                lines.append("  No nighttime forecast data available.")
                return lines.joined(separator: "\n")
            }

            for hour in nightHours.prefix(12) {
                let time = df.string(from: hour.time)
                let cloud = hour.cloudCover
                let seeingStr = seeingDescription(hour.seeing)
                let transStr = transparencyDescription(hour.transparency)
                var line = "  \(time): cloud \(cloud)%, seeing \(seeingStr), transparency \(transStr)"
                if let wind = hour.windSpeed { line += ", wind \(Int(wind))km/h" }
                if let temp = hour.temperature { line += ", \(Int(temp))°C" }
                if let hum = hour.humidity { line += ", humidity \(hum)%" }
                lines.append(line)
            }

            // Overall assessment
            let avgCloud = nightHours.prefix(8).map { $0.cloudCover }.reduce(0, +) / max(1, min(8, nightHours.count))
            let avgSeeing = nightHours.prefix(8).map { $0.seeing }.reduce(0, +) / max(1, min(8, nightHours.count))

            if avgCloud > 70 {
                lines.append("  VERDICT: Mostly cloudy tonight — not ideal for imaging.")
            } else if avgCloud > 40 {
                lines.append("  VERDICT: Partly cloudy — gaps may allow narrowband imaging.")
            } else if avgSeeing > 5 {
                lines.append("  VERDICT: Clear but poor seeing — favor short focal lengths or lucky imaging.")
            } else {
                lines.append("  VERDICT: Good conditions for imaging tonight!")
            }

            return lines.joined(separator: "\n")
        }

        private func seeingDescription(_ value: Int) -> String {
            switch value {
            case 1: return "<0.5\" superb"
            case 2: return "0.5-0.75\" excellent"
            case 3: return "0.75-1\" good"
            case 4: return "1-1.25\" average"
            case 5: return "1.25-1.5\" below avg"
            case 6: return "1.5-2\" poor"
            case 7: return "2-2.5\" bad"
            case 8: return ">2.5\" terrible"
            default: return "unknown"
            }
        }

        private func transparencyDescription(_ value: Int) -> String {
            switch value {
            case 1: return "<0.3mag superb"
            case 2: return "0.3-0.4mag excellent"
            case 3: return "0.4-0.5mag good"
            case 4: return "0.5-0.6mag average"
            case 5: return "0.6-0.7mag below avg"
            case 6: return "0.7-0.85mag poor"
            case 7: return "0.85-1mag bad"
            case 8: return ">1mag terrible"
            default: return "unknown"
            }
        }
    }

    // Fetch forecast for given coordinates (cached for 1 hour)
    func getForecast(lat: Double, lon: Double) async -> AstroForecast? {
        // Return cache if fresh and same location
        if let cached = cachedForecast, let cacheTime = cacheTime,
           Date().timeIntervalSince(cacheTime) < 3600,
           cachedLat == lat, cachedLon == lon {
            return cached
        }

        // Fetch from both APIs in parallel
        async let sevenTimer = fetch7Timer(lat: lat, lon: lon)
        async let openMeteo = fetchOpenMeteo(lat: lat, lon: lon)

        let seeing = await sevenTimer
        let weather = await openMeteo

        guard !seeing.isEmpty || !weather.isEmpty else { return nil }

        // Merge: 7Timer has seeing/transparency/cloud, Open-Meteo has wind/temp/humidity
        var hours: [AstroForecast.HourlyForecast] = []

        for s in seeing {
            let sTime = s.time
            let matching = weather.first { (entry: OpenMeteoEntry) -> Bool in
                Swift.abs(entry.time.timeIntervalSince(sTime)) < 5400
            }
            hours.append(AstroForecast.HourlyForecast(
                time: s.time,
                cloudCover: s.cloudCover,
                seeing: s.seeing,
                transparency: s.transparency,
                windSpeed: matching?.windSpeed,
                temperature: matching?.temperature,
                humidity: matching?.humidity,
                dewPoint: matching?.dewPoint
            ))
        }

        // Build 1-hourly cloud cover array from Open-Meteo data
        let hourlyCloud = weather.compactMap { entry -> AstroForecast.HourlyCloud? in
            guard let cloud = entry.cloudCover else { return nil }
            return AstroForecast.HourlyCloud(time: entry.time, cloudCover: cloud)
        }

        let forecast = AstroForecast(hours: hours, hourlyCloud: hourlyCloud, fetchTime: Date())
        cachedForecast = forecast
        cacheTime = Date()
        cachedLat = lat
        cachedLon = lon
        return forecast
    }

    // MARK: - 7Timer API (seeing, transparency, cloud cover)

    private struct SevenTimerEntry {
        let time: Date
        let cloudCover: Int
        let seeing: Int
        let transparency: Int
    }

    private func fetch7Timer(lat: Double, lon: Double) async -> [SevenTimerEntry] {
        let urlStr = "https://www.7timer.info/bin/api.pl?lon=\(lon)&lat=\(lat)&product=astro&output=json"
        guard let url = URL(string: urlStr) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let initStr = json["init"] as? String,
                  let dataseries = json["dataseries"] as? [[String: Any]] else { return [] }

            // Parse init time: "2026032006" → 2026-03-20 06:00 UTC
            let df = DateFormatter()
            df.dateFormat = "yyyyMMddHH"
            df.timeZone = TimeZone(identifier: "UTC")
            guard let initTime = df.date(from: initStr) else { return [] }

            var entries: [SevenTimerEntry] = []
            for point in dataseries {
                guard let timepoint = point["timepoint"] as? Int,
                      let cloudcover = point["cloudcover"] as? Int,
                      let seeing = point["seeing"] as? Int,
                      let transparency = point["transparency"] as? Int else { continue }

                let time = initTime.addingTimeInterval(Double(timepoint) * 3600)
                // 7Timer cloudcover: 1-9 scale → convert to percentage
                let cloudPct = min(100, max(0, (cloudcover - 1) * 12))

                entries.append(SevenTimerEntry(
                    time: time, cloudCover: cloudPct,
                    seeing: seeing, transparency: transparency
                ))
            }
            return entries
        } catch {
            print("[AIsaac Weather] 7Timer error: \(error)")
            return []
        }
    }

    // MARK: - Open-Meteo API (wind, temperature, humidity, dew point)

    private struct OpenMeteoEntry {
        let time: Date
        let cloudCover: Int?
        let windSpeed: Double?
        let temperature: Double?
        let humidity: Int?
        let dewPoint: Double?
    }

    private func fetchOpenMeteo(lat: Double, lon: Double) async -> [OpenMeteoEntry] {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&hourly=cloud_cover,temperature_2m,relative_humidity_2m,wind_speed_10m,dew_point_2m&forecast_days=2&timezone=auto"
        guard let url = URL(string: urlStr) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hourly = json["hourly"] as? [String: Any],
                  let times = hourly["time"] as? [String] else { return [] }

            let clouds = hourly["cloud_cover"] as? [Int?]
            let temps = hourly["temperature_2m"] as? [Double?]
            let humidity = hourly["relative_humidity_2m"] as? [Int?]
            let wind = hourly["wind_speed_10m"] as? [Double?]
            let dew = hourly["dew_point_2m"] as? [Double?]

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd'T'HH:mm"
            df.timeZone = TimeZone(identifier: "UTC")

            var entries: [OpenMeteoEntry] = []
            for (i, timeStr) in times.enumerated() {
                guard let time = df.date(from: timeStr) else { continue }
                entries.append(OpenMeteoEntry(
                    time: time,
                    cloudCover: clouds?[safe: i] ?? nil,
                    windSpeed: wind?[safe: i] ?? nil,
                    temperature: temps?[safe: i] ?? nil,
                    humidity: humidity?[safe: i] ?? nil,
                    dewPoint: dew?[safe: i] ?? nil
                ))
            }
            return entries
        } catch {
            print("[AIsaac Weather] Open-Meteo error: \(error)")
            return []
        }
    }
}

// Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
