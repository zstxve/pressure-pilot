import AppKit
import Darwin
import ServiceManagement

enum PressureLevel: Int {
    case normal = 1, warn = 2, critical = 4

    /// The kernel's own verdict, the same value that drives the graph in Activity Monitor.
    static func current() -> PressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return PressureLevel(rawValue: Int(level)) ?? .normal
    }
}

struct MemoryStats {
    var total: UInt64
    var used: UInt64  // app + wired + compressed, like "Memory Used" in Activity Monitor
    var compressed: UInt64
    var swapUsed: UInt64

    static func current() -> MemoryStats {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        let appPages = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0
        let compressed = UInt64(vm.compressor_page_count) * page

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        return MemoryStats(
            total: total,
            used: UInt64(appPages) * page + UInt64(vm.wire_count) * page + compressed,
            compressed: compressed,
            swapUsed: swap.xsu_used
        )
    }
}

struct AppUsage: Identifiable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    let footprint: UInt64  // including helper processes (renderers, WebContent, ...)
    let pids: [pid_t]      // the app and all its helpers
    let isFrontmost: Bool
    let isPlayingAudio: Bool
    let lastActive: Date
    var id: pid_t { pid }

    /// Bigger and longer unused means a better candidate to close.
    func score(now: Date) -> Double {
        let idleMinutes = min(now.timeIntervalSince(lastActive) / 60, 120)
        return Double(footprint) * (1 + idleMinutes / 15)
    }
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

/// Private libsystem call Activity Monitor uses to attribute helpers (e.g. Safari's WebContent) to their app.
private let responsiblePID: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

enum ProcessScanner {
    static func scan(lastActive: [String: Date]) -> [AppUsage] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != own
        }
        var totals: [pid_t: UInt64] = [:]
        var members: [pid_t: [pid_t]] = [:]
        for app in apps { totals[app.processIdentifier] = 0 }
        for pid in allPIDs() where pid > 0 {
            if let owner = owner(of: pid, among: totals) {
                totals[owner, default: 0] += footprint(of: pid)
                members[owner, default: []].append(pid)
            }
        }

        let now = Date()
        let playing = AudioActivity.playingPIDs()
        return apps.map { app in
            let id = app.bundleIdentifier!
            let pids = members[app.processIdentifier] ?? [app.processIdentifier]
            return AppUsage(
                pid: app.processIdentifier,
                bundleID: id,
                name: app.localizedName ?? id,
                icon: app.icon,
                footprint: totals[app.processIdentifier] ?? 0,
                pids: pids,
                isFrontmost: app.isActive,
                isPlayingAudio: pids.contains(where: playing.contains),
                lastActive: app.isActive ? now : (lastActive[id] ?? app.launchDate ?? now)
            )
        }
        .sorted { $0.footprint > $1.footprint }
    }

    static func dump() {
        let stats = MemoryStats.current()
        print("Druck: \(PressureLevel.current())  RAM: \(formatBytes(stats.used)) / \(formatBytes(stats.total))  Swap: \(formatBytes(stats.swapUsed))")
        print("Autostart: \(SMAppService.mainApp.status.label)")
        for app in scan(lastActive: [:]).prefix(15) {
            print("\(formatBytes(app.footprint).padding(toLength: 10, withPad: " ", startingAt: 0))  \(app.name)\(app.isPlayingAudio ? "  ♪" : "")")
        }
    }

    private static func owner(of pid: pid_t, among apps: [pid_t: UInt64]) -> pid_t? {
        if let responsible = responsiblePID?(pid), apps[responsible] != nil { return responsible }
        var current = pid
        for _ in 0..<8 {
            if apps[current] != nil { return current }
            current = parent(of: current)
            if current <= 1 { return nil }
        }
        return nil
    }

    private static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return Array(pids.prefix(Int(max(found, 0))))
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
