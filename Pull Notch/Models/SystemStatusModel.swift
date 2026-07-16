import Darwin
import Foundation
import Observation

nonisolated struct SystemStatusSnapshot: Equatable, Sendable {
    let cpuUsage: Double?
    let usedMemoryBytes: UInt64?
    let totalMemoryBytes: UInt64?
    let availableStorageBytes: Int64?
    let totalStorageBytes: Int64?

    var memoryUsage: Double? {
        guard let usedMemoryBytes, let totalMemoryBytes, totalMemoryBytes > 0 else { return nil }
        return min(1, max(0, Double(usedMemoryBytes) / Double(totalMemoryBytes)))
    }

    var storageUsage: Double? {
        guard let availableStorageBytes, let totalStorageBytes, totalStorageBytes > 0 else { return nil }
        return min(1, max(0, 1 - (Double(availableStorageBytes) / Double(totalStorageBytes))))
    }

    var hasWarning: Bool {
        (cpuUsage ?? 0) >= 0.85
            || (memoryUsage ?? 0) >= 0.85
            || (storageUsage ?? 0) >= 0.90
    }

    static let unavailable = SystemStatusSnapshot(
        cpuUsage: nil,
        usedMemoryBytes: nil,
        totalMemoryBytes: nil,
        availableStorageBytes: nil,
        totalStorageBytes: nil
    )
}

nonisolated private struct CPUTicks: Sendable {
    let active: UInt64
    let total: UInt64
}

nonisolated private struct SystemStatusSampler {
    private var previousTicks: CPUTicks?

    mutating func sampleCPU() -> Double? {
        guard let current = cpuTicks() else { return nil }
        defer { previousTicks = current }
        guard let previousTicks,
              current.total >= previousTicks.total,
              current.active >= previousTicks.active else { return nil }
        let totalDelta = current.total - previousTicks.total
        guard totalDelta > 0 else { return nil }
        return min(1, max(0, Double(current.active - previousTicks.active) / Double(totalDelta)))
    }

    func sampleMemory() -> (used: UInt64, total: UInt64)? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let total = ProcessInfo.processInfo.physicalMemory
        // Inactive and speculative pages are reclaimable file cache. Counting
        // them as used makes a healthy Mac look permanently memory-starved.
        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let used = usedPages * UInt64(vm_page_size)
        return (min(total, used), total)
    }

    func sampleStorage() -> (available: Int64, total: Int64)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]),
        let available = values.volumeAvailableCapacityForImportantUsage,
        let total = values.volumeTotalCapacity else { return nil }
        return (available, Int64(total))
    }

    private func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(active: user + system + nice, total: user + system + idle + nice)
    }
}

@MainActor
@Observable
final class SystemStatusModel {
    private(set) var snapshot: SystemStatusSnapshot = .unavailable
    private(set) var isMonitoring = false
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var sampler = SystemStatusSampler()
    @ObservationIgnored private var cachedStorage: (available: Int64, total: Int64)?

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitoringTask = Task { [weak self] in
            var sampleIndex = 0
            while !Task.isCancelled, let self {
                self.sample(refreshStorage: sampleIndex == 0 || sampleIndex % 20 == 0)
                sampleIndex += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        snapshot = .unavailable
        onUpdate?()
    }

    private func sample(refreshStorage: Bool) {
        let cpu = sampler.sampleCPU()
        let memory = sampler.sampleMemory()
        if refreshStorage {
            cachedStorage = sampler.sampleStorage()
        }
        snapshot = SystemStatusSnapshot(
            cpuUsage: cpu,
            usedMemoryBytes: memory?.used,
            totalMemoryBytes: memory?.total,
            availableStorageBytes: cachedStorage?.available,
            totalStorageBytes: cachedStorage?.total
        )
        onUpdate?()
    }
}
