import Foundation

/// Open-Meteo 的天氣查詢與解析。不需要金鑰。
public enum OpenMeteo {
    public static func url(latitude: Double, longitude: Double) -> URL? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        return c?.url
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let precipitation_probability_max: [Int?]?
        }
        let current: Current
        let daily: Daily
    }

    public static func parse(_ data: Data, place: String, fetchedAtMs: Int64) -> WeatherInfo? {
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              let high = r.daily.temperature_2m_max.first,
              let low = r.daily.temperature_2m_min.first else { return nil }
        let rain = r.daily.precipitation_probability_max?.first.flatMap { $0 } ?? 0
        return WeatherInfo(
            place: place,
            tempC: r.current.temperature_2m,
            code: r.current.weather_code,
            text: text(for: r.current.weather_code),
            highC: high,
            lowC: low,
            rainPercent: rain,
            fetchedAtMs: fetchedAtMs
        )
    }

    /// WMO 天氣代碼對應的中文。
    public static func text(for code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大致晴朗"
        case 2: return "多雲"
        case 3: return "陰"
        case 45, 48: return "霧"
        case 51, 53, 55, 56, 57: return "毛毛雨"
        case 61, 63, 65, 66, 67: return "雨"
        case 71, 73, 75, 77: return "雪"
        case 80, 81, 82: return "陣雨"
        case 85, 86: return "陣雪"
        case 95, 96, 99: return "雷雨"
        default: return "未知"
        }
    }
}
