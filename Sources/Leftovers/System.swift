import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Battery, simulators and sleep holds. All read-only; none needs a permission prompt.
enum SystemInfo {
    static func battery() -> BatteryState {
        var onBattery = false, percent: Int?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            onBattery = (IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
            let list = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]) ?? []
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                   let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = cur * 100 / max
                }
            }
        }
        return BatteryState(onBattery: onBattery, percent: percent, capacityWh: capacityWh,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Full-charge energy of the battery today (worn batteries hold less than new).
    static let capacityWh: Double = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(service) }
        guard service != 0 else { return 0 }
        func prop(_ k: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let data = prop("BatteryData") as? [String: Any]
        let mAh = (prop("AppleRawMaxCapacity") as? Int) ?? (data?["NominalChargeCapacity"] as? Int)
            ?? (prop("NominalChargeCapacity") as? Int) ?? (data?["DesignCapacity"] as? Int)
        let mV = (prop("Voltage") as? Int) ?? 11_400
        guard let mAh, mAh > 0 else { return 60 }   // typical MacBook Pro, if the battery won't say
        return Double(mAh) * Double(mV) / 1_000_000
    }()

    struct Simulator { var udid: String; var name: String; var runtime: String }

    /// Booted simulators, read from CoreSimulator's own device files (no xcrun call needed).
    static func bootedSimulators() -> [Simulator] {
        let root = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices"
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return ids.compactMap { id in
            guard let data = FileManager.default.contents(atPath: "\(root)/\(id)/device.plist"),
                  let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  (d["state"] as? Int) == 3 else { return nil }
            let runtime = ((d["runtime"] as? String) ?? "").split(separator: ".").last.map {
                $0.replacingOccurrences(of: "iOS-", with: "iOS ").replacingOccurrences(of: "-", with: ".")
            } ?? ""
            return Simulator(udid: (d["UDID"] as? String) ?? id, name: (d["name"] as? String) ?? "Simulator", runtime: runtime)
        }
    }


}
