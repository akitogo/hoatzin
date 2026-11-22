import Foundation
import Darwin

/// Small helpers for the app's private Unix-domain sockets (askpass and AI control).
/// Each request is one JSON object on one line, and so is each reply.
enum UnixSocket {
    /// The per-user temporary directory from the system, ignoring a TMPDIR override, so
    /// processes started by other apps (AI clients) find the same path.
    static var userTemporaryDirectory: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            return String(cString: buffer)
        }
        return NSTemporaryDirectory()
    }

    /// Creates, binds (mode 600) and listens on a socket at `path`.
    static func listen(at path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("Hoatzin: socket() failed"); return nil }
        guard var addr = address(path) else {
            NSLog("Hoatzin: socket path too long: \(path)"); close(fd); return nil
        }
        unlink(path)
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            NSLog("Hoatzin: bind/listen on \(path) failed: \(String(cString: strerror(errno)))")
            close(fd); return nil
        }
        chmod(path, 0o600)
        return fd
    }

    /// Connects to `path`; nil if nothing is listening.
    static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = address(path) else { if fd >= 0 { close(fd) }; return nil }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    /// Runs `serve` on its own thread for every accepted connection, until the socket closes.
    static func acceptLoop(_ listenFD: Int32, name: String, serve: @escaping @Sendable (Int32) -> Void) {
        let thread = Thread {
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { serve(client) }
            }
        }
        thread.name = name
        thread.start()
    }

    /// True if the peer runs as the same user as this process.
    static func isSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Reads one line (without the newline), giving up after `timeout` seconds of silence.
    static func readLine(_ fd: Int32, timeout: Int = 10, limit: Int = 1 << 20) -> Data {
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A), data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        if let newline = data.firstIndex(of: 0x0A) { data = data[..<newline] }
        return data
    }

    /// Writes a JSON object followed by a newline.
    static func writeLine(_ fd: Int32, _ object: [String: Any]) {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }
}
