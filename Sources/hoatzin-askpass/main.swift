// hoatzin-askpass
//
// Tiny SSH_ASKPASS helper. ssh runs it whenever it needs a password, a key
// passphrase or a yes/no confirmation. It never touches a secret itself: it
// forwards the prompt to the running Hoatzin app over a private Unix
// socket together with the session token, and prints whatever the app answers.
// The app checks that the caller is this binary, started by the ssh the token
// belongs to.
//
// With HOATZIN_BIND=1 (used once by external-terminal launchers right before
// `exec ssh`) it instead binds the token to its parent shell.

import Foundation
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hoatzin-askpass: \(message)\n".utf8))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
guard let socketPath = env["HOATZIN_SOCKET"], let token = env["HOATZIN_TOKEN"] else {
    fail("not started by Hoatzin (missing HOATZIN_SOCKET / HOATZIN_TOKEN)")
}

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let kind = env["SSH_ASKPASS_PROMPT"] ?? ""

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket() failed") }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path too long") }
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: pathBytes)
}
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

let connected = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { fail("cannot reach Hoatzin (is the app still running?)") }

let request: [String: String] = env["HOATZIN_BIND"] == "1"
    ? ["token": token, "op": "bind"]
    : ["token": token, "prompt": prompt, "kind": kind]
guard var payload = try? JSONSerialization.data(withJSONObject: request) else { fail("encode failed") }
payload.append(0x0A)

let wrote = payload.withUnsafeBytes { raw -> Bool in
    var offset = 0
    while offset < raw.count {
        let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if n <= 0 { return false }
        offset += n
    }
    return true
}
guard wrote else { fail("write failed") }

var response = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while !response.contains(0x0A) {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    response.append(buffer, count: n)
}
close(fd)

guard
    let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
    object["ok"] as? Bool == true
else {
    exit(1) // cancelled by the user, or refused by the app
}

if let value = object["value"] as? String {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}
exit(0)
