import Foundation
import Observation

nonisolated struct BatteryUpdate: Equatable, Sendable {
    let didChange: Bool
    let shouldShowChargingPower: Bool
    let shouldClearChargingPower: Bool
}

nonisolated struct AccessoryBatteryDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let level: Int
    let detailText: String
    let symbolName: String
    let isConnected: Bool
}

@MainActor
@Observable
final class BatteryModel {
    private(set) var level: Int?
    private(set) var isCharging = false
    private(set) var chargingWatts: Double?
    private(set) var accessoryDevices: [AccessoryBatteryDevice] = []

    @discardableResult
    func update(
        level: Int?,
        isCharging: Bool,
        chargingWatts: Double?,
        canShowChargingPower: Bool
    ) -> BatteryUpdate {
        let normalizedLevel = level.map { max(0, min(100, $0)) }
        let normalizedWatts = chargingWatts.flatMap { $0 >= 0 ? $0 : nil }
        let previousIsCharging = self.isCharging
        let previousWatts = self.chargingWatts
        let didChange = self.level != normalizedLevel
            || previousIsCharging != isCharging
            || wattsChanged(from: previousWatts, to: normalizedWatts, threshold: 0.1)

        self.level = normalizedLevel
        self.isCharging = isCharging
        self.chargingWatts = normalizedWatts

        let shouldShowChargingPower: Bool
        if canShowChargingPower, isCharging, let currentWatts = self.chargingWatts {
            shouldShowChargingPower = !previousIsCharging
                || previousWatts == nil
                || wattsChanged(from: previousWatts, to: currentWatts, threshold: 2)
        } else {
            shouldShowChargingPower = false
        }

        return BatteryUpdate(
            didChange: didChange,
            shouldShowChargingPower: shouldShowChargingPower,
            shouldClearChargingPower: !isCharging
        )
    }

    @discardableResult
    func updateAccessoryDevices(_ devices: [AccessoryBatteryDevice]) -> Bool {
        guard accessoryDevices != devices else { return false }
        accessoryDevices = devices
        return true
    }

    var symbolName: String? {
        guard let level else { return nil }
        switch level {
        case 90...100:
            return isCharging ? "bolt.fill" : "battery.100percent"
        case 50..<90:
            return isCharging ? "bolt.fill" : "battery.75percent"
        case 20..<50:
            return isCharging ? "bolt.fill" : "battery.50percent"
        default:
            return isCharging ? "bolt.fill" : "battery.25percent"
        }
    }

    var chargingPowerText: String? {
        guard let chargingWatts else { return nil }
        if chargingWatts >= 10 {
            return "\(Int(chargingWatts.rounded()))W"
        }
        return String(format: "%.1fW", chargingWatts)
    }

    func showsLowWarning(canPresent: Bool) -> Bool {
        guard canPresent, let level else { return false }
        return level < 10 && !isCharging
    }

    private func wattsChanged(
        from oldValue: Double?,
        to newValue: Double?,
        threshold: Double
    ) -> Bool {
        switch (oldValue, newValue) {
        case (nil, nil):
            return false
        case let (oldValue?, newValue?):
            return abs(oldValue - newValue) >= threshold
        default:
            return true
        }
    }
}
