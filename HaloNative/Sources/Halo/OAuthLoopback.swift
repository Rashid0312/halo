import Foundation
import Darwin

/// A loopback-only, single-attempt OAuth callback server. Never logs request URLs.
final class OAuthLoopback: @unchecked Sendable {
    let redirect: URL
    private let socketFD: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChatGPTFailure("Could not start the local sign-in callback.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw ChatGPTFailure("Could not bind the local sign-in callback.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw ChatGPTFailure("Could not configure the local callback.") }
        socketFD = fd
        redirect = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/auth/callback")!
    }

    deinit { close(socketFD) }

    func wait(state: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline {
                    if stopped { throw CancellationError() }
                    let client = accept(socketFD, nil, nil)
                    if client < 0 { usleep(20_000); continue }
                    defer { close(client) }
                    var timeout = timeval(tv_sec: 2, tv_usec: 0), noSignal: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    var request = Data(), buffer = [UInt8](repeating: 0, count: 2048)
                    while request.count < 8192 && !stopped {
                        let count = Darwin.read(client, &buffer, min(buffer.count, 8192 - request.count))
                        if count <= 0 { break }
                        request.append(contentsOf: buffer.prefix(count))
                        if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
                    }
                    let first = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                    let pieces = first.split(separator: " ")
                    let url = pieces.count == 3 && pieces[0] == "GET" ? URL(string: String(pieces[1]), relativeTo: redirect)?.absoluteURL : nil
                    let valid = url?.path == "/auth/callback" && url?.host == "127.0.0.1" && URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name == "state" }).map(\.value) == [state]
                    let body = valid ? "Sign-in response received. Return to Halo to finish connecting." : "Invalid callback. Return to Halo and try again."
                    let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
                    response.withCString { _ = Darwin.write(client, $0, response.utf8.count) }
                    if valid, let url { return url }
                }
                throw ChatGPTFailure("ChatGPT sign-in timed out. Try again.")
            }.value
        } onCancel: { self.cancel() }
    }
}
