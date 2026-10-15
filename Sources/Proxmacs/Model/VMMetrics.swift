import Darwin
import Foundation

/// One averaged sample of a VM's resource use.
struct VMSample: Sendable {
    var time: Date
    /// Share of the VM's virtual CPUs in use, 0…1.
    var cpu: Double
    /// Host memory of the VM process (physical footprint).
    var memory: Double
    /// Memory in use inside the guest (MemTotal − MemAvailable) and its total, from the guest agent.
    var guestUsed: Double?
    var guestTotal: Double?
    /// Bytes per second.
    var diskRead: Double
    var diskWrite: Double
    var netIn: Double?
    var netOut: Double?
}

enum MetricsRange: String, CaseIterable {
    case hour, day, week

    /// Seconds per point and points kept.
    var step: TimeInterval { switch self { case .hour: 10; case .day: 60; case .week: 1800 } }
    var capacity: Int { switch self { case .hour: 360; case .day: 1440; case .week: 336 } }
}

/// Per-VM resource history, sampled every 10 s while VMs run. The guest's CPU, memory and disk I/O are
/// measured on its Virtualization.framework process on the host (found by the disk image it has open);
/// network traffic and guest memory come from /proc inside the guest, through the guest agent.
@MainActor
final class VMMetrics {
    private struct Counters {
        var time: Date
        var cpu: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var netIn: UInt64?
        var netOut: UInt64?
    }

    private final class Series {
        var points: [VMSample] = []
        var bucket: Int?
        var pending: [VMSample] = []
    }

    private var pids: [String: pid_t] = [:]
    private var previous: [String: Counters] = [:]
    private var series: [String: [MetricsRange: Series]] = [:]
    private var agentBackoff: [String: Date] = [:]
    private(set) var latest: [String: VMSample] = [:]
    private(set) var started: [String: Date] = [:]

    /// Time until just after the next hour-chart bucket starts. Sampling then puts one sample in every
    /// bucket; a fixed interval drifts by the time each round takes and leaves gaps in the chart.
    static var untilNextSample: Duration {
        let step = MetricsRange.hour.step
        return .milliseconds(Int((step - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: step) + 0.5) * 1000))
    }

    func sample(running: [VMItem], tart: Tart) async {
        let names = Set(running.map(\.name))
        for gone in Set(previous.keys).subtracting(names) {
            previous[gone] = nil
            latest[gone] = nil
            started[gone] = nil
        }
        if running.contains(where: { pids[$0.name].map { !Self.isVMProcess($0) } ?? true }) {
            pids = Self.vmProcesses()
        }

        // Guest counters for all VMs at once.
        let guests = await withTaskGroup(of: (String, GuestCounters?).self) { group in
            for item in running where (agentBackoff[item.name] ?? .distantPast) < Date() {
                group.addTask { (item.name, await Self.guestCounters(item.name, tart: tart)) }
            }
            var result: [String: GuestCounters] = [:]
            for await (name, counters) in group {
                if let counters { result[name] = counters } else { agentBackoff[name] = Date().addingTimeInterval(60) }
            }
            return result
        }

        let now = Date()
        for item in running {
            guard let pid = pids[item.name], let usage = Self.usage(pid) else { continue }
            started[item.name] = usage.started
            let guest = guests[item.name]
            let current = Counters(time: now, cpu: usage.cpuNanos, diskRead: usage.diskRead, diskWrite: usage.diskWrite,
                                   netIn: guest?.netIn, netOut: guest?.netOut)
            defer { previous[item.name] = current }
            guard let last = previous[item.name] else { continue }
            let seconds = now.timeIntervalSince(last.time)
            guard seconds > 0 else { continue }
            func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / seconds : 0 }
            let cpus = Double(max(item.cpus ?? 1, 1))
            var netIn: Double?, netOut: Double?
            if let a = current.netIn, let b = last.netIn, let c = current.netOut, let d = last.netOut {
                netIn = rate(a, b)
                netOut = rate(c, d)
            }
            let sample = VMSample(
                time: now, cpu: min(rate(current.cpu, last.cpu) / 1e9 / cpus, 1), memory: Double(usage.footprint),
                guestUsed: guest.map { Double($0.memUsed) }, guestTotal: guest.map { Double($0.memTotal) },
                diskRead: rate(current.diskRead, last.diskRead), diskWrite: rate(current.diskWrite, last.diskWrite),
                netIn: netIn, netOut: netOut)
            latest[item.name] = sample
            record(item.name, sample)
        }
    }

    func history(_ vm: String, range: MetricsRange) -> [VMSample] {
        guard let s = series[vm]?[range] else { return [] }
        return s.points + (s.pending.isEmpty ? [] : [Self.average(s.pending, at: s.pending.last!.time)])
    }

    func forget(_ vm: String) {
        series[vm] = nil
        previous[vm] = nil
        latest[vm] = nil
    }

    private func record(_ vm: String, _ sample: VMSample) {
        for range in MetricsRange.allCases {
            let s = series[vm, default: [:]][range] ?? Series()
            series[vm, default: [:]][range] = s
            let bucket = Int(sample.time.timeIntervalSince1970 / range.step)
            if let current = s.bucket, current != bucket, !s.pending.isEmpty {
                s.points.append(Self.average(s.pending, at: Date(timeIntervalSince1970: TimeInterval(current + 1) * range.step)))
                if s.points.count > range.capacity { s.points.removeFirst(s.points.count - range.capacity) }
                s.pending = []
            }
            s.bucket = bucket
            s.pending.append(sample)
        }
    }

    private static func average(_ samples: [VMSample], at time: Date) -> VMSample {
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }
        func optional(_ values: [Double?]) -> Double? {
            let present = values.compactMap { $0 }
            return present.isEmpty ? nil : mean(present)
        }
        return VMSample(time: time, cpu: mean(samples.map(\.cpu)), memory: mean(samples.map(\.memory)),
                        guestUsed: optional(samples.map(\.guestUsed)), guestTotal: optional(samples.map(\.guestTotal)),
                        diskRead: mean(samples.map(\.diskRead)), diskWrite: mean(samples.map(\.diskWrite)),
                        netIn: optional(samples.map(\.netIn)), netOut: optional(samples.map(\.netOut)))
    }

    // MARK: - Host processes

    private static let vzProcess = "com.apple.Virtualization.VirtualMachine"

    private static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cBuffer: buffer)
    }

    private static func isVMProcess(_ pid: pid_t) -> Bool {
        path(pid)?.hasSuffix("/" + vzProcess) == true
    }

    /// VM name → its Virtualization.framework process, matched by the open disk.img in Tart's VM directory.
    static func vmProcesses() -> [String: pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var all = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [:] }
        let vmsDir = Paths.tartHome.appending(path: "vms").resolvingSymlinksInPath().path + "/"
        var result: [String: pid_t] = [:]
        for pid in all.prefix(Int(filled)) where pid > 0 && isVMProcess(pid) {
            for file in openFiles(pid) where file.hasSuffix("/disk.img") {
                let resolved = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
                guard resolved.hasPrefix(vmsDir) else { continue }
                let parts = resolved.dropFirst(vmsDir.count).split(separator: "/")
                if parts.count == 2 { result[String(parts[0])] = pid }
            }
        }
        return result
    }

    private static func openFiles(_ pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard n == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }
    }

    private struct ProcessUsage {
        var cpuNanos: UInt64
        var footprint: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var started: Date
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func usage(_ pid: pid_t) -> ProcessUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var bsd = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        let started = n > 0 ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)) : Date()
        // CPU times are in Mach absolute time units (not nanoseconds on Apple Silicon).
        let ticks = info.ri_user_time + info.ri_system_time
        let nanos = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return ProcessUsage(cpuNanos: nanos, footprint: info.ri_phys_footprint, diskRead: info.ri_diskio_bytesread,
                            diskWrite: info.ri_diskio_byteswritten, started: started)
    }

    // MARK: - Guest

    struct GuestCounters: Sendable {
        var netIn: UInt64
        var netOut: UInt64
        var memTotal: UInt64
        var memUsed: UInt64
    }

    nonisolated private static func guestCounters(_ vm: String, tart: Tart) async -> GuestCounters? {
        guard let result = try? await tart.exec(vm, ["cat", "/proc/net/dev", "/proc/meminfo"], timeout: 5), result.succeeded else {
            return nil
        }
        return parseGuest(result.stdout)
    }

    nonisolated static func parseGuest(_ text: String) -> GuestCounters? {
        var netIn: UInt64 = 0, netOut: UInt64 = 0
        var memory: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let fields = line[line.index(after: colon)...].split(separator: " ")
                if line.hasSuffix("kB") || fields.count == 1 {
                    if let value = fields.first.flatMap({ UInt64($0) }) { memory[key] = value * (line.hasSuffix("kB") ? 1024 : 1) }
                } else if fields.count >= 9, key != "lo" {
                    netIn += UInt64(fields[0]) ?? 0
                    netOut += UInt64(fields[8]) ?? 0
                }
            }
        }
        guard let total = memory["MemTotal"], let available = memory["MemAvailable"] else { return nil }
        return GuestCounters(netIn: netIn, netOut: netOut, memTotal: total, memUsed: total - min(available, total))
    }
}

extension HostStats {
    private nonisolated(unsafe) static var lastTicks: (busy: UInt64, total: UInt64)?

    /// Share of all host CPUs busy since the previous call (nil on the first).
    static func cpuUsage() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let now = (busy: user + system + nice, total: user + system + nice + idle)
        defer { lastTicks = now }
        guard let last = lastTicks, now.total > last.total else { return nil }
        return Double(now.busy - last.busy) / Double(now.total - last.total)
    }
}
