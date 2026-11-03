import Darwin
import Foundation

// MARK: - Snapshot types

struct CPUSample {
    var user: Double = 0      // 0...1
    var system: Double = 0
    var total: Double { min(1, user + system) }
}

struct MemorySample {
    var used: UInt64 = 0          // app + wired + compressed (Activity Monitor "Memory Used")
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0        // file-backed + purgeable
    var active: UInt64 = 0
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    var pressure: Int32 = 1       // 1 normal, 2 warn, 4 critical
    /// Activity Monitor's "Memory Used" (App + Wired + Compressed).
    var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    /// Active + Wired + Compressed: excludes inactive app pages; closer to what Usage shows.
    var activeFraction: Double { total == 0 ? 0 : min(1, Double(active + wired + compressed) / Double(total)) }
}

struct NetSample {
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var totalDown: UInt64 = 0     // since boot, across counted interfaces
    var totalUp: UInt64 = 0
    var interfaces: [String] = [] // interfaces that are up and counted
}

// MARK: - Sampler

/// Reads CPU, memory and network counters straight from the kernel (no shelling out).
final class Sampler {
    private let host = mach_host_self()
    private var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private var lastNet: (counters: [String: NetMath.Counters], time: UInt64)?
    private var lastSampleTime: UInt64 = 0

    /// Readings over very short windows are noise: a few scheduler ticks can read as 50% or 100% CPU.
    /// Calls closer together than this keep the previous values.
    static let minInterval: Double = 0.25

    private(set) var cpu = CPUSample()
    private(set) var memory = MemorySample()
    private(set) var net = NetSample()
    /// Number of samples actually taken (calls ignored by `minInterval` don't count).
    private(set) var samplesTaken = 0

    func sample() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if samplesTaken > 0, Double(now &- lastSampleTime) / 1e9 < Sampler.minInterval { return }
        lastSampleTime = now
        samplesTaken += 1
        sampleCPU()
        sampleMemory()
        sampleNetwork()
    }

    // CPU: delta of aggregate host tick counters since the previous sample.
    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = info.cpu_ticks // (user, system, idle, nice)
        let now = (user: t.0, sys: t.1, idle: t.2, nice: t.3)
        defer { lastTicks = now }
        guard let prev = lastTicks else { return }
        // UInt32 tick counters can wrap; wrapping subtraction handles that.
        let user = Double(now.user &- prev.user) + Double(now.nice &- prev.nice)
        let sys = Double(now.sys &- prev.sys)
        let idle = Double(now.idle &- prev.idle)
        let total = user + sys + idle
        guard total > 0 else { return }
        cpu = CPUSample(user: user / total, system: sys / total)
    }

    private func sampleMemory() {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(vm.internal_page_count)
        let purgeable = UInt64(vm.purgeable_count)
        var m = MemorySample()
        m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        m.wired = UInt64(vm.wire_count) * page
        m.compressed = UInt64(vm.compressor_page_count) * page
        m.cached = (UInt64(vm.external_page_count) + purgeable) * page
        m.active = UInt64(vm.active_count) * page
        m.used = m.app + m.wired + m.compressed

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = swap.xsu_used }

        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressure = level }
        memory = m
    }

    // Network: 64-bit interface counters via NET_RT_IFLIST2 (getifaddrs' if_data is 32-bit and wraps at 4 GB).
    // Only physical "en*" interfaces are counted, so VPN tunnels (utun*) don't double count traffic.
    private func sampleNetwork() {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return }

        var counters: [String: NetMath.Counters] = [:]
        var names: [String] = []
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                if msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    let flags = Int32(h2.ifm_flags)
                    if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                            let name = String(cString: nameBuf)
                            if name.hasPrefix("en") {
                                counters[name] = NetMath.Counters(down: h2.ifm_data.ifi_ibytes, up: h2.ifm_data.ifi_obytes)
                                if h2.ifm_data.ifi_ibytes > 0 || h2.ifm_data.ifi_obytes > 0 { names.append(name) }
                            }
                        }
                    }
                }
                off += msglen
            }
        }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { lastNet = (counters, now) }
        var n = NetSample()
        n.totalDown = counters.values.reduce(0) { $0 &+ $1.down }
        n.totalUp = counters.values.reduce(0) { $0 &+ $1.up }
        n.interfaces = names.sorted()
        if let prev = lastNet, now > prev.time {
            let dt = Double(now - prev.time) / 1e9
            let moved = NetMath.delta(from: prev.counters, to: counters)
            n.downBytesPerSec = Double(moved.down) / dt
            n.upBytesPerSec = Double(moved.up) / dt
        }
        net = n
    }
}

enum NetMath {
    struct Counters: Equatable { var down: UInt64; var up: UInt64 }

    /// Bytes moved between two per-interface counter snapshots. Only interfaces present in both count:
    /// an interface that just came up (e.g. Wi-Fi reconnecting) would otherwise add its whole since-boot
    /// total as one huge spike, and one that went away would cancel out real traffic on the others.
    /// A counter that went backwards (interface reset) contributes nothing.
    static func delta(from prev: [String: Counters], to now: [String: Counters]) -> Counters {
        var moved = Counters(down: 0, up: 0)
        for (name, c) in now {
            guard let p = prev[name] else { continue }
            if c.down >= p.down { moved.down &+= c.down - p.down }
            if c.up >= p.up { moved.up &+= c.up - p.up }
        }
        return moved
    }
}

// MARK: - Formatting

enum Fmt {
    /// Very compact rate for the menu bar: at most 4 characters, e.g. "0", "512K", "8.1M", "81M", "1.2G".
    static func compactRate(_ bytesPerSec: Double, bits: Bool) -> String {
        var v = bits ? bytesPerSec * 8 : bytesPerSec
        let units = ["", "K", "M", "G", "T"]
        var i = 0
        // 1000-based for both, like Usage / Activity Monitor network rates.
        while v >= 999.5 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return v < 1 ? "0" : String(format: "%.0f", v) }
        if v < 9.95 { return String(format: "%.1f%@", v, units[i]) }
        return String(format: "%.0f%@", v, units[i])
    }

    static func rate(_ bytesPerSec: Double, bits: Bool) -> String {
        let c = compactRate(bytesPerSec, bits: bits)
        let suffix = bits ? "b/s" : "B/s"
        if c == "0" { return "0 " + (bits ? "Kb/s" : "KB/s") }
        if let last = c.last, last.isLetter { return "\(c.dropLast()) \(last)\(suffix)" }
        return "\(c) \(suffix)"
    }

    private static func formatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false   // "0 KB" rather than "Zero KB"
        return f
    }
    private static let memFmt = formatter(.memory)
    private static let fileFmt = formatter(.file)
    static func bytes(_ b: UInt64) -> String { memFmt.string(fromByteCount: Int64(clamping: b)) }
    static func fileBytes(_ b: UInt64) -> String { fileFmt.string(fromByteCount: Int64(clamping: b)) }

    static func pct(_ f: Double) -> String { String(format: "%.0f%%", (f * 100).rounded()) }
}
