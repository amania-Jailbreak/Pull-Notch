import Foundation

nonisolated struct WeatherForecastDay: Identifiable, Equatable, Sendable {
    let date: Date
    let highTemperature: Int
    let lowTemperature: Int
    let symbolName: String

    var id: Date { date }
}
