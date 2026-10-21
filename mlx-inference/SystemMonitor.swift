import Darwin
import Foundation
import MLX
import Observation

/// Samples RAM, app memory and per-core CPU usage once per second.
@Observable
final class SystemMonitor {
    /// Total physical RAM in bytes.
    let totalRAM = ProcessInfo.processInfo.physicalMemory
    /// RAM in use across the whole system (active + wired + compressed).
    var usedRAM: UInt64 = 0
    /// This app's memory footprint (what Activity Monitor shows as "Memory").
    var appMemory: UInt64 = 0
    /// Memory MLX currently holds for model weights and activations.
    var mlxActiveMemory: Int = 0
    /// Peak MLX memory since launch.
    var mlxPeakMemory: Int = 0
    /// Usage of each CPU core, 0...1.
    var coreUsage: [Double] = []
    /// Average usage across all cores, 0...1.
    var totalCPU: Double { coreUsage.isEmpty ? 0 : coreUsage.reduce(0, +) / Double(coreUsage.count) }

    private var previousTicks: [(busy: UInt64, total: UInt64)] = []
    private var timer: Timer?

    init() {
        start()
    }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        usedRAM = Self.systemUsedRAM()
        appMemory = Self.appFootprint()
        let snapshot = MLX.Memory.snapshot()
        mlxActiveMemory = snapshot.activeMemory
        mlxPeakMemory = snapshot.peakMemory
        sampleCores()
    }

    private static func systemUsedRAM() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * pageSize
    }

    private static func appFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func sampleCores() {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS,
              let infoArray else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)]))
            let busy = user + system + nice
            ticks.append((busy, busy + idle))
        }

        if previousTicks.count == ticks.count {
            coreUsage = zip(ticks, previousTicks).map { now, before in
                let total = now.total &- before.total
                return total == 0 ? 0 : Double(now.busy &- before.busy) / Double(total)
            }
        } else {
            coreUsage = Array(repeating: 0, count: ticks.count)
        }
        previousTicks = ticks
    }
}
