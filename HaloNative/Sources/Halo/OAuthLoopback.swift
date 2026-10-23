import Foundation
import Darwin

/// A loopback-only, single-attempt OAuth callback server. Never logs request URLs.
final class OAuthLoopback: @unchecked Sendable {
    let redirect: URL
    private let service: String
    private let socketFD: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    /// `port` 0 picks a free port; services that only accept a registered
    /// redirect address need a fixed one.
    init(port: UInt16 = 0, service: String = "ChatGPT") throws {
        self.service = service
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChatGPTFailure("Could not start the local sign-in callback.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw ChatGPTFailure(port == 0 ? "Could not bind the local sign-in callback." : "Port \(port) for the sign-in callback is in use.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw ChatGPTFailure("Could not configure the local callback.") }
        socketFD = fd
        redirect = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/auth/callback")!
    }

    deinit { close(socketFD) }

    /// The page the browser shows after sign-in: Halo's name and what to do
    /// next, never the callback address or its parameters.
    static func page(service: String, valid: Bool) -> String {
        let name = service.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let title = valid ? "\(name) is connecting to Halo" : "This sign-in link is no longer valid"
        let detail = valid ? "You can close this tab. Halo will confirm when the connection is ready." : "Close this tab and start again from Halo."
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Halo</title><style>
        :root{color-scheme:light dark}body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px -apple-system,system-ui,sans-serif;background:#f5f5f7;color:#1d1d1f}
        @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}.card{background:#2c2c2e!important}}
        .card{background:#fff;border-radius:18px;padding:40px 44px;max-width:420px;text-align:center;box-shadow:0 10px 40px rgba(0,0,0,.08)}
        .mark{width:56px;height:56px;margin:0 auto 18px;border-radius:50%;background:radial-gradient(circle at 35% 30%,#a5b4fc,#6366f1 60%,#4338ca)}
        h1{font-size:20px;margin:0 0 8px}p{margin:0;opacity:.7;line-height:1.45}
        </style></head><body><div class="card"><div class="mark"></div><h1>\(title)</h1><p>\(detail)</p></div></body></html>
        """
    }

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
                    let body = Self.page(service: service, valid: valid)
                    let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
                    response.withCString { _ = Darwin.write(client, $0, response.utf8.count) }
                    if valid, let url { return url }
                }
                throw ChatGPTFailure("\(service) sign-in timed out. Try again.")
            }.value
        } onCancel: { self.cancel() }
    }
}
