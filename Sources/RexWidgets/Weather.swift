import AppKit
import CoreLocation
import SwiftUI

/// Current conditions for the Mac's location, from Open-Meteo (free, no key).
final class WeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Conditions {
        var temperature: Double
        var feelsLike: Double
        var high: Double
        var low: Double
        var code: Int
        var isDay: Bool
        var windSpeed: Double
        var humidity: Double
        var precipChance: Double?
        var fetched: Date
    }

    enum Phase {
        case loading
        case needsLocation(String)
        case failed(String)
        case ready(Conditions)
    }

    @Published var phase: Phase = .loading
    @Published var place: String?

    private let manager = CLLocationManager()
    private var location: CLLocation?
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 20 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        checkAuthorization()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        manager.requestLocation()
    }

    private func checkAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            phase = .needsLocation("Location access is off for Rex Widgets.")
        default:
            manager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        checkAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let moved = location.map { $0.distance(from: latest) > 2000 } ?? true
        location = latest
        if moved { lookUpPlace(latest) }
        fetch(latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let location {
            fetch(location) // keep using the last known spot
        } else if case .ready = phase {
            // keep showing what we have
        } else {
            phase = .failed("Couldn't get your location.")
        }
    }

    // MARK: Data

    private func lookUpPlace(_ location: CLLocation) {
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] marks, _ in
            guard let mark = marks?.first else { return }
            DispatchQueue.main.async { self?.place = mark.locality ?? mark.name }
        }
    }

    private func fetch(_ location: CLLocation) {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", location.coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", location.coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,relative_humidity_2m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: Self.usesFahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: Self.usesFahrenheit ? "mph" : "kmh"),
        ]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, error in
            let result = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.phase = .ready(result)
                } else if case .ready = self.phase {
                    // keep the last good reading on a transient failure
                } else {
                    self.phase = .failed(error == nil ? "Unexpected weather data." : "Couldn't reach the weather service.")
                }
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> Conditions? {
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let apparent_temperature: Double
                let weather_code: Int
                let is_day: Int
                let wind_speed_10m: Double
                let relative_humidity_2m: Double
            }
            struct Daily: Decodable {
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
                let precipitation_probability_max: [Double?]?
            }
            let current: Current
            let daily: Daily
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              let high = r.daily.temperature_2m_max.first, let low = r.daily.temperature_2m_min.first
        else { return nil }
        return Conditions(
            temperature: r.current.temperature_2m, feelsLike: r.current.apparent_temperature,
            high: high, low: low, code: r.current.weather_code, isDay: r.current.is_day == 1,
            windSpeed: r.current.wind_speed_10m, humidity: r.current.relative_humidity_2m,
            precipChance: r.daily.precipitation_probability_max?.first ?? nil, fetched: Date()
        )
    }

    static var usesFahrenheit: Bool {
        Locale.current.measurementSystem == .us
    }

    static var windUnit: String { usesFahrenheit ? "mph" : "km/h" }

    /// WMO weather codes → description and SF Symbol.
    static func describe(code: Int, isDay: Bool) -> (text: String, symbol: String) {
        switch code {
        case 0: return ("Clear", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1: return ("Mostly clear", isDay ? "sun.max.fill" : "moon.fill")
        case 2: return ("Partly cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45, 48: return ("Fog", "cloud.fog.fill")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57: return ("Freezing drizzle", "cloud.sleet.fill")
        case 61: return ("Light rain", "cloud.rain.fill")
        case 63: return ("Rain", "cloud.rain.fill")
        case 65: return ("Heavy rain", "cloud.heavyrain.fill")
        case 66, 67: return ("Freezing rain", "cloud.sleet.fill")
        case 71: return ("Light snow", "cloud.snow.fill")
        case 73: return ("Snow", "cloud.snow.fill")
        case 75: return ("Heavy snow", "snowflake")
        case 77: return ("Snow grains", "snowflake")
        case 80, 81: return ("Rain showers", isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill")
        case 82: return ("Violent showers", "cloud.heavyrain.fill")
        case 85, 86: return ("Snow showers", "cloud.snow.fill")
        case 95: return ("Thunderstorm", "cloud.bolt.rain.fill")
        case 96, 99: return ("Thunderstorm, hail", "cloud.bolt.rain.fill")
        default: return ("Unknown", "questionmark.circle")
        }
    }
}

struct WeatherWidget: View {
    @ObservedObject var model: WeatherModel

    var body: some View {
        WidgetCard(title: model.place ?? "Weather", systemImage: "location.fill") {
            switch model.phase {
            case .loading:
                Text("Getting the weather…").foregroundStyle(.secondary)
            case .needsLocation(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).foregroundStyle(.secondary)
                    Button("Open Location Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    }
                    .controlSize(.small)
                }
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { model.refresh() }.controlSize(.small)
                }
            case .ready(let c):
                ready(c)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.refresh() }
        .help("Click to refresh")
    }

    private func ready(_ c: WeatherModel.Conditions) -> some View {
        let d = WeatherModel.describe(code: c.code, isDay: c.isDay)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: d.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 30))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(c.temperature.rounded()))°")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                    Text(d.text).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("H \(Int(c.high.rounded()))°")
                    Text("L \(Int(c.low.rounded()))°").foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            HStack(spacing: 12) {
                stat("thermometer.medium", "Feels \(Int(c.feelsLike.rounded()))°")
                stat("wind", "\(Int(c.windSpeed.rounded())) \(WeatherModel.windUnit)")
                stat("humidity", "\(Int(c.humidity.rounded()))%")
                if let p = c.precipChance {
                    stat("umbrella", "\(Int(p.rounded()))%")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Text("Updated \(c.fetched.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .lineLimit(1)
    }
}
