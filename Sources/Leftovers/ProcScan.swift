import Darwin
import Foundation

/// Low-level reads of the process table through libproc. None of this needs any permission:
/// it only looks at processes owned by the current user.
enum ProcScan {
    private static let ticksToSeconds: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    /// Every process of this user, with the cheap facts (parent, path, folder, arguments).
    static func allProcesses() -> [ProcRecord] {
        let uid = getuid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [ProcRecord] = []
        out.reserveCapacity(Int(got))
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            let path = execPath(pid)
            let name = cString(info.pbi_name).isEmpty ? cString(info.pbi_comm) : cString(info.pbi_name)
            out.append(ProcRecord(
                pid: pid,
                ppid: pid_t(info.pbi_ppid),
                name: name.isEmpty ? (path as NSString).lastPathComponent : name,
                path: path,
                args: arguments(pid),
                cwd: workingDirectory(pid),
                start: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))))
        }
        return out
    }

    /// When a process started, or nil if it is gone (used to make sure a pid wasn't reused).
    static func startTime(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec)
    }

    /// Total CPU seconds and energy (joules) the process has used since it started.
    static func usage(_ pid: pid_t) -> (cpu: Double, joules: Double, memoryMB: Double)? {
        var ru = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard r == 0 else { return nil }
        let cpu = Double(ru.ri_user_time + ru.ri_system_time) * ticksToSeconds
        return (cpu, Double(ru.ri_energy_nj) / 1e9, Double(ru.ri_phys_footprint) / 1_048_576)
    }

    /// Files the process has open for writing, and its TCP sockets.
    static func openFiles(_ pid: pid_t) -> (writes: [WrittenFile], listening: [UInt16], established: [UInt16]) {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return ([], [], []) }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))) / stride
        var writes: [WrittenFile] = [], listening: [UInt16] = [], established: [UInt16] = []
        for fd in fds.prefix(max(got, 0)) {
            if fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var v = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &v, size) == size,
                      v.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
                let path = cString(v.pvip.vip_path)
                let st = v.pvip.vip_vi.vi_stat
                // Only real files count as "output" (not terminals, /dev/null, pipes).
                guard !path.isEmpty, !path.hasPrefix("/dev/"), (st.vst_mode & S_IFMT) == S_IFREG else { continue }
                writes.append(WrittenFile(path: path, size: Int64(st.vst_size),
                                          modified: Date(timeIntervalSince1970: TimeInterval(st.vst_mtime))))
            } else if fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var s = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &s, size) == size,
                      s.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                let tcp = s.psi.soi_proto.pri_tcp
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                switch tcp.tcpsi_state {
                case Int32(TSI_S_LISTEN): listening.append(port)
                case Int32(TSI_S_ESTABLISHED): established.append(port)
                default: break
                }
            }
        }
        return (writes, Array(Set(listening)).sorted(), established)
    }

    // MARK: helpers

    private static func execPath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    private static func workingDirectory(_ pid: pid_t) -> String {
        var v = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, size) == size else { return "" }
        return cString(v.pvi_cdir.vip_path)
    }

    /// Command-line arguments (argv), read with sysctl KERN_PROCARGS2.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }      // executable path
        while i < size && buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let s = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}
