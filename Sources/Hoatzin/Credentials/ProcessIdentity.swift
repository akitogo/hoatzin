import Darwin

/// A running process, identified by pid *and* start time so a recycled pid never matches.
/// `exec` keeps both, so a launcher shell that execs ssh keeps its identity.
struct ProcessIdentity: Equatable, Sendable, CustomStringConvertible {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init?(pid: pid_t) {
        guard pid > 0, let info = Self.bsdInfo(pid) else { return nil }
        self.pid = pid
        startSeconds = info.pbi_start_tvsec
        startMicroseconds = info.pbi_start_tvusec
    }

    var description: String { "pid \(pid)" }

    /// Path of the running executable, resolved by the kernel.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        guard let info = bsdInfo(pid), info.pbi_ppid > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The process itself and up to `depth` ancestors, nearest first.
    static func lineage(from pid: pid_t, depth: Int) -> [ProcessIdentity] {
        var result: [ProcessIdentity] = []
        var current: pid_t? = pid
        while let pid = current, result.count <= depth, let identity = ProcessIdentity(pid: pid) {
            result.append(identity)
            current = parent(of: pid)
        }
        return result
    }

    /// The pid at the other end of a connected Unix-domain socket.
    static func peerPID(of fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// `realpath`, so symlinks and /private prefixes compare equal to what the kernel reports.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
