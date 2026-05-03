// AIsaac — Astronomy weather forecast via Meteoblue
// Proxied through Supabase Edge Function (weather-forecast) with caching + rate limiting.
// Provides 1-hourly cloud layers, visibility, temp, humidity, wind, fog for 7 days.
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
        let fetchTime: Date

        struct HourlyForecast {
            let time: Date
            let cloudCover: Int          // % total (0=clear, 100=overcast)
            let lowClouds: Int           // % low cloud layer
            let midClouds: Int           // % mid cloud layer
            let highClouds: Int          // % high cloud layer
            let visibility: Int          // meters (>20000 = excellent transparency)
            let temperature: Double      // celsius
            let feltTemperature: Double  // celsius (wind chill)
            let humidity: Int            // %
            let windSpeed: Double        // m/s (display as km/h: ×3.6)
            let windDirection: Int       // degrees
            let fogProbability: Int      // %
            let precipProbability: Int   // %
            let isDaylight: Bool
            let pressure: Double         // hPa

            // Derived: wind speed in km/h
            var windSpeedKmh: Double { windSpeed * 3.6 }

            // Derived: dew point approximation (Magnus formula)
            var dewPoint: Double {
                let a = 17.27, b = 237.7
                let alpha = (a * temperature) / (b + temperature) + log(Double(humidity) / 100.0)
                return (b * alpha) / (a - alpha)
            }

            // Derived: transparency quality from visibility
            var transparencyQuality: String {
                switch visibility {
                case 30_000...: return "Superb"
                case 20_000..<30_000: return "Excellent"
                case 15_000..<20_000: return "Good"
                case 10_000..<15_000: return "Average"
                case 5_000..<10_000: return "Below avg"
                default: return "Poor"
                }
            }

            // Derived: seeing estimate from visibility + high clouds + wind + humidity
            // Meteoblue doesn't provide actual seeing — this is a multi-factor heuristic.
            // Visibility is the strongest proxy (low vis = moisture/aerosols = bad seeing).
            var seeingEstimate: String {
                // Cloudy conditions: don't estimate seeing, it's irrelevant
                if cloudCover > 70 { return "Cloudy" }
                // Visibility is the primary driver (atmospheric transparency correlates with seeing)
                if visibility < 5_000 { return "Very poor (>3\")" }
                if visibility < 10_000 { return "Poor (2-3\")" }
                // High clouds + jet stream wind = upper atmosphere turbulence
                let windKmh = windSpeed * 3.6
                if visibility < 15_000 || (highClouds > 30 && windKmh > 25) { return "Below avg (1.5-2\")" }
                if highClouds > 20 || windKmh > 30 { return "Below avg (1.5-2\")" }
                // High humidity degrades seeing even without clouds
                if humidity > 85 && visibility < 20_000 { return "Below avg (1.5-2\")" }
                // Good conditions require clear air
                if visibility > 30_000 && highClouds < 5 && windKmh < 15 { return "Very good (<1\")" }
                if visibility > 20_000 && highClouds < 10 && windKmh < 20 { return "Good (1-1.5\")" }
                return "Average (~1.5\")"
            }

            // Numeric seeing score 1-8 (1=superb, 8=terrible) for sorting/comparison
            var seeingScore: Int {
                if cloudCover > 70 { return 8 }
                if visibility < 5_000 { return 8 }
                if visibility < 10_000 { return 7 }
                if visibility < 15_000 { return 6 }
                let windKmh = windSpeed * 3.6
                if highClouds > 20 || windKmh > 30 { return 6 }
                if humidity > 85 && visibility < 20_000 { return 5 }
                if visibility > 30_000 && highClouds < 5 && windKmh < 15 { return 2 }
                if visibility > 20_000 && highClouds < 10 && windKmh < 20 { return 3 }
                return 4
            }
        }

        // Convenience: hourly cloud data for the 1h bar chart (backward compatible)
        var hourlyCloud: [HourlyForecast] { hours }

        // Human-readable summary for AIsaac context
        func contextSummary(timezone: TimeZone) -> String {
            var lines: [String] = ["TONIGHT'S WEATHER FORECAST (Meteoblue):"]

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
                let vis = hour.transparencyQuality
                let seeing = hour.seeingEstimate
                var line = "  \(time): cloud \(cloud)% (hi:\(hour.highClouds)% mid:\(hour.midClouds)% lo:\(hour.lowClouds)%)"
                line += ", vis \(vis), seeing \(seeing)"
                line += ", wind \(Int(hour.windSpeedKmh))km/h, \(Int(hour.temperature))°C, humidity \(hour.humidity)%"
                if hour.fogProbability > 10 { line += ", fog \(hour.fogProbability)%" }
                lines.append(line)
            }

            // Overall assessment
            let avgCloud = nightHours.prefix(8).map { $0.cloudCover }.reduce(0, +) / max(1, min(8, nightHours.count))
            let avgHigh = nightHours.prefix(8).map { $0.highClouds }.reduce(0, +) / max(1, min(8, nightHours.count))
            let avgVis = nightHours.prefix(8).map { $0.visibility }.reduce(0, +) / max(1, min(8, nightHours.count))

            if avgCloud > 70 {
                lines.append("  VERDICT: Mostly cloudy tonight — not ideal for imaging.")
            } else if avgCloud > 40 {
                lines.append("  VERDICT: Partly cloudy — gaps may allow narrowband imaging.")
            } else if avgHigh > 30 {
                lines.append("  VERDICT: High clouds present — seeing may be poor, favor short FL.")
            } else if avgVis < 10000 {
                lines.append("  VERDICT: Low transparency — narrowband preferred over broadband.")
            } else {
                lines.append("  VERDICT: Good conditions for imaging tonight!")
            }

            return lines.joined(separator: "\n")
        }
    }

    // Fetch forecast via Supabase Edge Function (cached for 1 hour)
    func getForecast(lat: Double, lon: Double) async -> AstroForecast? {
        // Return cache if fresh and same location
        if let cached = cachedForecast, let cacheTime = cacheTime,
           Date().timeIntervalSince(cacheTime) < 3600,
           cachedLat == lat, cachedLon == lon {
            return cached
        }

        guard let forecast = await fetchMeteoblue(lat: lat, lon: lon) else {
            return nil
        }

        cachedForecast = forecast
        cacheTime = Date()
        cachedLat = lat
        cachedLon = lon
        return forecast
    }

    // MARK: - Meteoblue via Supabase Edge Function

    private func fetchMeteoblue(lat: Double, lon: Double) async -> AstroForecast? {
        guard BenchmarkConfig.isConfigured else {
            print("[AIsaac Weather] Supabase not configured")
            return nil
        }

        guard var request = SupabaseClient.functionRequest("weather-forecast") else { return nil }
        let deviceId = MachineInfo.machineHash
        let body: [String: Any] = ["lat": lat, "lon": lon, "deviceId": deviceId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            // No retry: 429 from the rate-limited edge function is handled below as a
            // first-class result, and a transient retry would mask that signal.
            let (data, response) = try await SupabaseClient.send(request)

            if response.statusCode == 429 {
                print("[AIsaac Weather] Rate limited by Supabase Edge Function")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let data1h = json["data_1h"] as? [String: Any],
                  let metadata = json["metadata"] as? [String: Any],
                  let times = data1h["time"] as? [String] else {
                print("[AIsaac Weather] Invalid Meteoblue response")
                return nil
            }

            // Parse timezone offset for time conversion
            let utcOffset = metadata["utc_timeoffset"] as? Double ?? 0

            let totalCloud = data1h["totalcloudcover"] as? [Int] ?? []
            let lowCloud = data1h["lowclouds"] as? [Int] ?? []
            let midCloud = data1h["midclouds"] as? [Int] ?? []
            let highCloud = data1h["highclouds"] as? [Int] ?? []
            let visibility = data1h["visibility"] as? [Int] ?? []
            let temperature = data1h["temperature"] as? [Double] ?? []
            let feltTemp = data1h["felttemperature"] as? [Double] ?? []
            let humidity = data1h["relativehumidity"] as? [Int] ?? []
            let windSpeed = data1h["windspeed"] as? [Double] ?? []
            let windDir = data1h["winddirection"] as? [Int] ?? []
            let fog = data1h["fog_probability"] as? [Int] ?? []
            let precip = data1h["precipitation_probability"] as? [Int] ?? []
            let daylight = data1h["isdaylight"] as? [Int] ?? []
            let pressure = data1h["sealevelpressure"] as? [Double] ?? []

            // Parse time strings: "2026-04-07 00:00" (local time at utcOffset)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            df.timeZone = TimeZone(secondsFromGMT: Int(utcOffset * 3600))

            var hours: [AstroForecast.HourlyForecast] = []
            for (i, timeStr) in times.enumerated() {
                guard let time = df.date(from: timeStr) else { continue }
                hours.append(AstroForecast.HourlyForecast(
                    time: time,
                    cloudCover: totalCloud[safe: i] ?? 0,
                    lowClouds: lowCloud[safe: i] ?? 0,
                    midClouds: midCloud[safe: i] ?? 0,
                    highClouds: highCloud[safe: i] ?? 0,
                    visibility: visibility[safe: i] ?? 10000,
                    temperature: temperature[safe: i] ?? 0,
                    feltTemperature: feltTemp[safe: i] ?? 0,
                    humidity: humidity[safe: i] ?? 0,
                    windSpeed: windSpeed[safe: i] ?? 0,
                    windDirection: windDir[safe: i] ?? 0,
                    fogProbability: fog[safe: i] ?? 0,
                    precipProbability: precip[safe: i] ?? 0,
                    isDaylight: (daylight[safe: i] ?? 1) == 1,
                    pressure: pressure[safe: i] ?? 1013
                ))
            }

            return AstroForecast(hours: hours, fetchTime: Date())
        } catch {
            print("[AIsaac Weather] Meteoblue fetch error: \(error)")
            return nil
        }
    }
}

// Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
