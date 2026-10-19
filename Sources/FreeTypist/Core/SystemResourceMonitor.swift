import Cocoa
import Carbon
import Darwin
import Foundation
import IOKit.ps
import Combine

@MainActor
public final class SystemResourceMonitor: ObservableObject {
    public static let shared = SystemResourceMonitor()

    @Published public private(set) var appMemoryMB: Double = 24.0
    @Published public private(set) var isOnBatteryPower: Bool = false
    @Published public private(set) var batteryPercentage: Int = 100
    @Published public private(set) var isSecureInputActive: Bool = false
    @Published public private(set) var isMacOSInlinePredictionEnabled: Bool = false
    @Published public private(set) var cpuChipName: String = "Apple Silicon"
    @Published public private(set) var totalSystemMemoryGB: Int = 16

    private var monitorTimer: Timer?

    private init() {
        self.cpuChipName = Self.readCPUModel()
        self.totalSystemMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        refreshMetrics()
        startLightweightMonitoring()
    }

    public func startLightweightMonitoring() {
        monitorTimer?.invalidate()
        // Poll every 10 seconds with 2s tolerance for timer coalescing -> ~0.0% CPU impact
        let timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetrics()
            }
        }
        timer.tolerance = 2.0
        self.monitorTimer = timer
    }

    public func refreshMetrics() {
        self.appMemoryMB = Self.currentProcessMemoryMB()
        let power = Self.readBatteryStatus()
        self.isOnBatteryPower = power.onBattery
        self.batteryPercentage = power.percent
        self.isSecureInputActive = IsSecureEventInputEnabled()
        self.isMacOSInlinePredictionEnabled = Self.checkMacOSInlinePrediction()
    }

    public static func currentProcessMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 24.0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    private static func readCPUModel() -> String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let slice = buffer.prefix { $0 != 0 }
        let str = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? "Apple Silicon" : str
    }

    private static func readBatteryStatus() -> (onBattery: Bool, percent: Int) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any] else {
            return (false, 100)
        }
        let state = desc[kIOPSPowerSourceStateKey as String] as? String
        let onBattery = (state == kIOPSBatteryPowerValue as String)
        let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
        return (onBattery, capacity)
    }

    private static func checkMacOSInlinePrediction() -> Bool {
        if let globalDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain),
           let val = globalDomain["NSAutomaticInlinePredictionEnabled"] as? Bool {
            return val
        }
        return false
    }

    public func disableMacOSInlinePredictions() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "-g", "NSAutomaticInlinePredictionEnabled", "-bool", "false"]
        try? task.run()
        task.waitUntilExit()
        refreshMetrics()
    }
}
