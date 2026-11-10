import Foundation
import IOKit.ps

/// Battery state, for pausing passive mode on low battery.
public enum PowerSource {
    public struct Status: Sendable, Equatable {
        public var onBattery: Bool
        /// Charge in percent, nil on a Mac without a battery.
        public var percent: Int?
    }

    public static func current() -> Status {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return Status(onBattery: false, percent: nil) }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = type == kIOPSBatteryPowerValue
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Status(onBattery: onBattery, percent: current * 100 / max)
        }
        return Status(onBattery: onBattery, percent: nil)
    }

    /// Whether passive mode should pause under the given threshold (0 = never, 100 = whenever on battery).
    public static func shouldPause(_ status: Status, threshold: Int) -> Bool {
        guard status.onBattery, threshold > 0 else { return false }
        if threshold >= 100 { return true }
        return (status.percent ?? 100) < threshold
    }
}
