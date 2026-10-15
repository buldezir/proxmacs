import Darwin
import Foundation

/// Host memory figures, computed the way Activity Monitor does
/// ("Memory Used" = app memory + wired + compressed).
struct HostMemory: Hashable {
    var total: UInt64
    var used: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    /// File-backed and purgeable memory the system can reclaim.
    var cached: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    /// 1 = normal, 2 = warning, 4 = critical (kern.memorystatus_vm_pressure_level).
    var pressure: Int

    var pressureLabel: String {
        switch pressure {
        case 4: "critical"
        case 2: "warning"
        default: "normal"
        }
    }
}

enum HostStats {
    static func memory() -> HostMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        let app = UInt64(stats.internal_page_count &- stats.purgeable_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = UInt64(stats.external_page_count &+ stats.purgeable_count) * page
        let free = UInt64(stats.free_count &- min(stats.speculative_count, stats.free_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }

        var pressure: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) != 0 { pressure = 1 }

        return HostMemory(total: ProcessInfo.processInfo.physicalMemory, used: app + wired + compressed,
                          app: app, wired: wired, compressed: compressed, cached: cached, free: free,
                          swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, pressure: Int(pressure))
    }

    /// Nested virtualization needs Apple M3 or later.
    static let supportsNestedVirtualization: Bool = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cBuffer: buffer)
        guard let range = brand.range(of: #"Apple M[0-9]+"#, options: .regularExpression),
              let generation = Int(brand[range].dropFirst("Apple M".count)) else { return false }
        return generation >= 3
    }()

    static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
}
