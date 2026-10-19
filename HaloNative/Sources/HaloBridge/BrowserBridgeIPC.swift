import Foundation
import Darwin
import Security

/// Message sent by HaloNativeHost upon connecting to Halo's local Unix Domain Socket.
public struct BridgeHostAuthMessage: Sendable, Codable, Equatable {
    public let authToken: String
    public let clientPID: Int32
    public let origin: String

    public init(authToken: String, clientPID: Int32, origin: String) {
        self.authToken = authToken
        self.clientPID = clientPID
        self.origin = origin
    }
}

/// Confirmation returned by Halo to HaloNativeHost upon successful peer authentication.
public struct BridgeHostAuthResponse: Sendable, Codable, Equatable {
    public let authenticated: Bool
    public let sessionNonce: String
    public let error: String?

    public init(authenticated: Bool, sessionNonce: String, error: String? = nil) {
        self.authenticated = authenticated
        self.sessionNonce = sessionNonce
        self.error = error
    }
}

/// Ephemeral session configuration written by Halo to a mode-0600 JSON file in a mode-0700 directory.
public struct BridgeSessionConfig: Sendable, Codable, Equatable {
    public let sessionDirectoryPath: String
    public let socketPath: String
    public let authToken: String
    public let sessionNonce: String
    public let hostPID: Int32
    public let pinnedExtensionID: String
    public let createdAt: Date

    public init(
        sessionDirectoryPath: String,
        socketPath: String,
        authToken: String,
        sessionNonce: String,
        hostPID: Int32,
        pinnedExtensionID: String,
        createdAt: Date = Date()
    ) {
        self.sessionDirectoryPath = sessionDirectoryPath
        self.socketPath = socketPath
        self.authToken = authToken
        self.sessionNonce = sessionNonce
        self.hostPID = hostPID
        self.pinnedExtensionID = pinnedExtensionID
        self.createdAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
    }

    /// Standard session configuration filename.
    public static let sessionFileName = "session.json"

    /// Default session file URL.
    public static func defaultSessionFile(in directory: URL? = nil) -> URL {
        if let dir = directory {
            return dir.appendingPathComponent(sessionFileName, isDirectory: false)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-bridge-session", isDirectory: true)
            .appendingPathComponent(sessionFileName, isDirectory: false)
    }

    /// Creates an unguessable private directory (mode 0700) for a single session.
    public static func createUniqueSessionDirectory() throws -> URL {
        let token = BridgeSocketIO.generateRandomHex(byteCount: 8)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb_\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        return dir
    }
}

/// Native Messaging host manifest generator and reversible installer.
public enum NativeMessagingInstaller {
    public static func defaultManifestDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Chromium/NativeMessagingHosts", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts", isDirectory: true)
        ]
    }

    /// Writes an atomic host manifest targeting the specified launcher path.
    public static func install(
        hostName: String,
        launcherPath: String,
        allowedOrigins: [String],
        targetDirectories: [URL]? = nil
    ) throws -> [URL] {
        guard !hostName.isEmpty, hostName.utf8.count <= 128,
              launcherPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: launcherPath),
              !allowedOrigins.isEmpty,
              allowedOrigins.allSatisfy({ $0.hasPrefix("chrome-extension://") && $0.hasSuffix("/") }) else {
            throw BridgeErrorDetails(code: .payloadMalformed, message: "Native Messaging manifest inputs are invalid.")
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Halo Browser Bridge Native Host",
            "path": launcherPath,
            "type": "stdio",
            "allowed_origins": allowedOrigins
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        var installed: [URL] = []
        let dirs = targetDirectories ?? defaultManifestDirectories()
        do {
            for dir in dirs {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileURL = dir.appendingPathComponent("\(hostName).json")
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    guard isAbandonedHaloManifest(at: fileURL, hostName: hostName) else {
                        throw BridgeErrorDetails(code: .internalError, message: "Refusing to overwrite an existing Native Messaging manifest at \(fileURL.path).")
                    }
                    try FileManager.default.removeItem(at: fileURL)
                }
                try data.write(to: fileURL, options: .atomic)
                installed.append(fileURL)
            }
        } catch {
            uninstall(manifestURLs: installed)
            throw error
        }
        return installed
    }

    /// A manifest is abandoned only when it is provably Halo's own: it launches a
    /// Halo session launcher in this user's temporary directory, and that session
    /// is gone or its owning Halo process has exited. Anything else is foreign.
    public static func isAbandonedHaloManifest(at fileURL: URL, hostName: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == hostName,
              let path = manifest["path"] as? String else { return false }
        let launcher = URL(fileURLWithPath: path).standardizedFileURL
        let sessionDir = launcher.deletingLastPathComponent()
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard launcher.lastPathComponent == "halo_host_launcher.sh",
              sessionDir.lastPathComponent.hasPrefix("hb_"),
              sessionDir.deletingLastPathComponent().resolvingSymlinksInPath().path == tempRoot else { return false }
        let sessionFile = sessionDir.appendingPathComponent(BridgeSessionConfig.sessionFileName)
        guard let sessionData = try? Data(contentsOf: sessionFile),
              let session = try? JSONDecoder().decode(BridgeSessionConfig.self, from: sessionData) else { return true }
        if session.hostPID == getpid() { return false }
        return kill(session.hostPID, 0) != 0 && errno == ESRCH
    }

    /// Reversibly unlinks all installed manifest files.
    public static func uninstall(manifestURLs: [URL]) {
        for url in manifestURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Helper for low-level socket operations with timeouts, cancellation, and peer verification.
public enum BridgeSocketIO {
    public static func generateRandomHex(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads exactly count bytes from a file descriptor with a deadline.
    public static func readExact(from fd: Int32, count: Int, deadline: Date) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            try Task.checkCancellation()
            if Date() > deadline {
                throw BridgeErrorDetails(code: .internalError, message: "Socket read deadline exceeded.")
            }
            var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pollFd, 1, 100) // 100ms slice to honor cancellation
            if pollResult < 0 {
                let err = errno
                if err == EINTR { continue }
                throw BridgeErrorDetails(code: .internalError, message: "Socket poll failed: errno \(err)")
            } else if pollResult == 0 {
                continue
            }
            if (pollFd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 && (pollFd.revents & Int16(POLLIN)) == 0 {
                throw BridgeErrorDetails(code: .internalError, message: "Socket disconnected during read.")
            }

            var chunk = [UInt8](repeating: 0, count: count - data.count)
            let readBytes = read(fd, &chunk, chunk.count)
            if readBytes < 0 {
                let err = errno
                if err == EINTR || err == EAGAIN { continue }
                throw BridgeErrorDetails(code: .internalError, message: "Socket read error: errno \(err)")
            } else if readBytes == 0 {
                throw BridgeErrorDetails(code: .internalError, message: "Socket reached EOF prematurely.")
            }
            data.append(contentsOf: chunk.prefix(readBytes))
        }
        return data
    }

    /// Writes all bytes to a file descriptor with a deadline.
    public static func writeAll(to fd: Int32, data: Data, deadline: Date) throws {
        var totalWritten = 0
        let bytes = Array(data)
        while totalWritten < bytes.count {
            try Task.checkCancellation()
            if Date() > deadline {
                throw BridgeErrorDetails(code: .internalError, message: "Socket write deadline exceeded.")
            }
            var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pollFd, 1, 100)
            if pollResult < 0 {
                let err = errno
                if err == EINTR { continue }
                throw BridgeErrorDetails(code: .internalError, message: "Socket write poll failed: errno \(err)")
            } else if pollResult == 0 {
                continue
            }
            if (pollFd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                throw BridgeErrorDetails(code: .internalError, message: "Socket closed during write.")
            }

            let writeBytes = bytes.withUnsafeBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return write(fd, base.advanced(by: totalWritten), bytes.count - totalWritten)
            }
            if writeBytes < 0 {
                let err = errno
                if err == EINTR || err == EAGAIN { continue }
                throw BridgeErrorDetails(code: .internalError, message: "Socket write error: errno \(err)")
            }
            totalWritten += writeBytes
        }
    }

    /// Reads a 4-byte little-endian framed payload from a socket descriptor.
    public static func readFramedData(from fd: Int32, timeoutSeconds: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let headerData = try readExact(from: fd, count: 4, deadline: deadline)
        let declared = headerData.enumerated().reduce(UInt32(0)) { partial, pair in
            partial | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
        guard declared <= UInt32(BrowserBridgeLimits.maxMessageSizeBytes) else {
            throw BridgeErrorDetails(code: .oversizedPayload, message: "Frame declared length \(declared) exceeds max limit.")
        }
        return try readExact(from: fd, count: Int(declared), deadline: deadline)
    }

    /// Writes a 4-byte little-endian framed payload to a socket descriptor.
    public static func writeFramedData(to fd: Int32, payload: Data, timeoutSeconds: TimeInterval) throws {
        guard payload.count <= BrowserBridgeLimits.maxMessageSizeBytes else {
            throw BridgeErrorDetails(code: .oversizedPayload, message: "Payload size exceeds maximum limit.")
        }
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        try writeAll(to: fd, data: frame, deadline: deadline)
    }

    /// Verifies peer credentials on an accepted Unix Domain Socket descriptor.
    /// Asserts effective UID, peer PID, canonical executable path, and macOS code signature validity.
    public static func verifyPeer(fd: Int32, expectedExecutableURL: URL? = nil) throws -> pid_t {
        // 1. UID check
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Failed to query peer credentials: errno \(errno)")
        }
        guard euid == geteuid() else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Peer UID \(euid) does not match process UID \(geteuid()).")
        }

        // 2. Kernel PID retrieval
        var peerPID: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &len) == 0 else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Failed to query LOCAL_PEERPID: errno \(errno)")
        }
        guard peerPID > 0 else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Invalid peer PID \(peerPID).")
        }

        // 3. Executable path verification
        var buffer = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(peerPID, &buffer, UInt32(buffer.count))
        guard pathLen > 0 else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Failed to determine peer process executable path.")
        }
        let rawPath = buffer.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }
        let canonicalExecPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path

        if let expected = expectedExecutableURL {
            let canonicalExpected = expected.resolvingSymlinksInPath().path
            guard canonicalExecPath == canonicalExpected else {
                throw BridgeErrorDetails(code: .authenticationFailed, message: "Connecting peer path '\(canonicalExecPath)' does not match expected helper '\(canonicalExpected)'.")
            }
        } else {
            guard canonicalExecPath.hasSuffix("/HaloNativeHost") || canonicalExecPath.hasSuffix("/Halo") else {
                throw BridgeErrorDetails(code: .authenticationFailed, message: "Connecting peer executable '\(canonicalExecPath)' is not authorized.")
            }
        }

        guard let expectedExecutableURL else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Expected helper identity is required for peer verification.")
        }

        // 4. Require the running peer to satisfy the exact helper's designated
        // requirement, rather than accepting any independently valid signature.
        var peerCode: SecCode?
        let attrs = [kSecGuestAttributePid: peerPID] as NSDictionary
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, SecCSFlags(rawValue: 0), &peerCode)
        guard copyStatus == errSecSuccess, let code = peerCode else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Failed to obtain code signature guest for peer PID \(peerPID) (status \(copyStatus)).")
        }

        var expectedStaticCode: SecStaticCode?
        let staticStatus = SecStaticCodeCreateWithPath(expectedExecutableURL as CFURL, SecCSFlags(rawValue: 0), &expectedStaticCode)
        var designatedRequirement: SecRequirement?
        let requirementStatus = expectedStaticCode.map {
            SecCodeCopyDesignatedRequirement($0, SecCSFlags(rawValue: 0), &designatedRequirement)
        } ?? errSecParam
        guard staticStatus == errSecSuccess, requirementStatus == errSecSuccess, let requirement = designatedRequirement else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Could not derive the expected helper designated requirement.")
        }
        let validityStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement)
        guard validityStatus == errSecSuccess else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Peer process failed macOS code signature validity check (status \(validityStatus)).")
        }

        return peerPID
    }
}

/// Actor managing the server side of the ephemeral Unix Domain Socket inside Halo.
public actor BridgeIPCServer {
    private let config: BridgeSessionConfig
    /// Credentials currently published in session.json; rotated while idle so a
    /// lazily launched helper always finds a fresh, short-lived token.
    private var issuedConfig: BridgeSessionConfig
    private let sessionDirectoryURL: URL
    private let launcherScriptURL: URL?
    private let expectedHelperURL: URL?
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var isClosed = false

    public init(
        pinnedExtensionID: String,
        helperExecutableURL: URL? = nil,
        customSessionDirectory: URL? = nil
    ) throws {
        let sessionDir = try customSessionDirectory ?? BridgeSessionConfig.createUniqueSessionDirectory()
        self.sessionDirectoryURL = sessionDir
        self.expectedHelperURL = helperExecutableURL

        let socketURL = sessionDir.appendingPathComponent("s.sock", isDirectory: false)
        let authToken = BridgeSocketIO.generateRandomHex(byteCount: 32)
        let sessionNonce = BridgeSocketIO.generateRandomHex(byteCount: 32)

        let config = BridgeSessionConfig(
            sessionDirectoryPath: sessionDir.path,
            socketPath: socketURL.path,
            authToken: authToken,
            sessionNonce: sessionNonce,
            hostPID: getpid(),
            pinnedExtensionID: pinnedExtensionID
        )
        self.config = config

        self.issuedConfig = config

        // 1. Write session.json with 0600 permissions
        try Self.writeSessionFile(config)

        // 2. Generate executable launcher script if helper path is known (mode 0700)
        if let helperURL = helperExecutableURL {
            let launcherURL = sessionDir.appendingPathComponent("halo_host_launcher.sh", isDirectory: false)
            let script = """
            #!/bin/sh
            exec "\(helperURL.path)" --session-dir "\(sessionDir.path)" "$@"
            """
            try script.write(to: launcherURL, atomically: true, encoding: .utf8)
            chmod(launcherURL.path, 0o700)
            self.launcherScriptURL = launcherURL
        } else {
            self.launcherScriptURL = nil
        }

        // 3. Setup Unix Domain Socket (mode 0600)
        unlink(socketURL.path)
        let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sfd >= 0 else {
            throw BridgeErrorDetails(code: .internalError, message: "Failed to create socket: errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard config.socketPath.utf8.count < maxPath else {
            Darwin.close(sfd)
            throw BridgeErrorDetails(code: .internalError, message: "Socket path is too long.")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), config.socketPath, maxPath - 1)
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sfd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else {
            Darwin.close(sfd)
            throw BridgeErrorDetails(code: .internalError, message: "Failed to bind socket: errno \(errno)")
        }
        chmod(config.socketPath, 0o600)

        guard listen(sfd, 1) == 0 else {
            Darwin.close(sfd)
            throw BridgeErrorDetails(code: .internalError, message: "Failed to listen on socket: errno \(errno)")
        }
        self.serverFD = sfd
    }

    nonisolated public var sessionConfig: BridgeSessionConfig { config }
    nonisolated public var launcherURL: URL? { launcherScriptURL }
    nonisolated public var directoryURL: URL { sessionDirectoryURL }
    public var isConnected: Bool { clientFD >= 0 && !isClosed }
    /// Kernel-verified PID of the currently connected helper, or 0.
    public private(set) var peerPID: pid_t = 0

    /// Waits for HaloNativeHost to connect, verifies peer credentials and auth token.
    public func acceptConnection(timeoutSeconds: TimeInterval = 10) async throws {
        guard serverFD >= 0, !isClosed else {
            throw BridgeErrorDetails(code: .internalError, message: "Server socket is closed.")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var cfd: Int32 = -1

        while cfd < 0 {
            try Task.checkCancellation()
            if Date() > deadline {
                throw BridgeErrorDetails(code: .internalError, message: "Timeout waiting for native host connection.")
            }
            var pfd = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
            let pres = poll(&pfd, 1, 100)
            if pres < 0 {
                let err = errno
                if err == EINTR { continue }
                throw BridgeErrorDetails(code: .internalError, message: "Accept poll failed: errno \(err)")
            } else if pres == 0 {
                continue
            }
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            cfd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(serverFD, sa, &clientLen)
                }
            }
            if cfd < 0 {
                let err = errno
                if err == EINTR || err == EAGAIN { continue }
                throw BridgeErrorDetails(code: .internalError, message: "Socket accept failed: errno \(err)")
            }
        }

        // 1. Peer verification (UID, PID, Executable Path, Code Signature)
        let verifiedPeerPID: pid_t
        do {
            verifiedPeerPID = try BridgeSocketIO.verifyPeer(fd: cfd, expectedExecutableURL: expectedHelperURL)
        } catch {
            Darwin.close(cfd)
            throw error
        }

        // 2. Read initial auth message from client
        let authData: Data
        do {
            authData = try BridgeSocketIO.readFramedData(from: cfd, timeoutSeconds: 5)
        } catch {
            Darwin.close(cfd)
            throw error
        }

        guard let authMsg = try? JSONDecoder().decode(BridgeHostAuthMessage.self, from: authData) else {
            Darwin.close(cfd)
            throw BridgeErrorDetails(code: .payloadMalformed, message: "Invalid host auth message payload.")
        }
        guard authMsg.clientPID == verifiedPeerPID else {
            Darwin.close(cfd)
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Host authentication PID does not match the kernel-reported peer PID.")
        }

        // 3. Constant-time token verification
        guard BridgeSessionValidator.constantTimeEquals(authMsg.authToken, issuedConfig.authToken) else {
            let resp = BridgeHostAuthResponse(authenticated: false, sessionNonce: "", error: "Auth token mismatch")
            if let respData = try? JSONEncoder().encode(resp) {
                try? BridgeSocketIO.writeFramedData(to: cfd, payload: respData, timeoutSeconds: 2)
            }
            Darwin.close(cfd)
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Host authentication token mismatch.")
        }

        // 4. Verify origin matches pinned extension ID
        let expectedOrigin = "chrome-extension://\(config.pinnedExtensionID)/"
        guard authMsg.origin == expectedOrigin || authMsg.origin == "chrome-extension://\(config.pinnedExtensionID)" else {
            let resp = BridgeHostAuthResponse(authenticated: false, sessionNonce: "", error: "Extension origin mismatch")
            if let respData = try? JSONEncoder().encode(resp) {
                try? BridgeSocketIO.writeFramedData(to: cfd, payload: respData, timeoutSeconds: 2)
            }
            Darwin.close(cfd)
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Host reported unpinned extension origin '\(authMsg.origin)'.")
        }

        // 5. Send auth success
        let resp = BridgeHostAuthResponse(authenticated: true, sessionNonce: config.sessionNonce)
        let respData = try JSONEncoder().encode(resp)
        try BridgeSocketIO.writeFramedData(to: cfd, payload: respData, timeoutSeconds: 5)

        self.clientFD = cfd
        self.peerPID = verifiedPeerPID
    }

    /// Sends a request envelope to the helper over the Unix Domain Socket.
    public func sendRequest(_ request: BridgeRequest, timeoutSeconds: TimeInterval = 5) throws {
        guard clientFD >= 0, !isClosed else {
            throw BridgeErrorDetails(code: .internalError, message: "Client socket is not connected.")
        }
        let framed = try BridgeMessageFraming.encode(request)
        try BridgeSocketIO.writeFramedData(to: clientFD, payload: framed, timeoutSeconds: timeoutSeconds)
    }

    public func sendMessage<T: Encodable>(_ message: T, timeoutSeconds: TimeInterval = 5) throws {
        guard clientFD >= 0, !isClosed else {
            throw BridgeErrorDetails(code: .internalError, message: "Client socket is not connected.")
        }
        try BridgeSocketIO.writeFramedData(to: clientFD, payload: BridgeMessageFraming.encode(message), timeoutSeconds: timeoutSeconds)
    }

    /// Receives a response envelope from the helper over the Unix Domain Socket.
    public func receiveResponse(timeoutSeconds: TimeInterval = 10) throws -> BridgeResponse {
        guard clientFD >= 0, !isClosed else {
            throw BridgeErrorDetails(code: .internalError, message: "Client socket is not connected.")
        }
        let payload = try BridgeSocketIO.readFramedData(from: clientFD, timeoutSeconds: timeoutSeconds)
        return try BridgeMessageFraming.decode(BridgeResponse.self, from: payload)
    }

    private static func writeSessionFile(_ config: BridgeSessionConfig) throws {
        let configData = try JSONEncoder().encode(config)
        let sessionFileURL = URL(fileURLWithPath: config.sessionDirectoryPath, isDirectory: true)
            .appendingPathComponent(BridgeSessionConfig.sessionFileName, isDirectory: false)
        let tempURL = sessionFileURL.appendingPathExtension("tmp")
        unlink(tempURL.path)
        let fd = open(tempURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw BridgeErrorDetails(code: .internalError, message: "Failed to open session.json: errno \(errno)")
        }
        let written = configData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, configData.count)
        }
        Darwin.close(fd)
        guard written == configData.count, rename(tempURL.path, sessionFileURL.path) == 0 else {
            unlink(tempURL.path)
            throw BridgeErrorDetails(code: .internalError, message: "Failed to publish session.json.")
        }
    }

    /// Issues a new helper auth token and freshness timestamp. The session nonce
    /// is unchanged; only a helper that reads the new file can authenticate.
    public func rotateCredentials() throws {
        guard !isClosed else {
            throw BridgeErrorDetails(code: .internalError, message: "Server socket is closed.")
        }
        let rotated = BridgeSessionConfig(
            sessionDirectoryPath: config.sessionDirectoryPath,
            socketPath: config.socketPath,
            authToken: BridgeSocketIO.generateRandomHex(byteCount: 32),
            sessionNonce: config.sessionNonce,
            hostPID: config.hostPID,
            pinnedExtensionID: config.pinnedExtensionID
        )
        try Self.writeSessionFile(rotated)
        issuedConfig = rotated
    }

    /// Age of the credentials currently published in session.json.
    public var credentialAge: TimeInterval { Date().timeIntervalSince(issuedConfig.createdAt) }

    /// Non-consuming check for a helper that exited or hung up.
    public func peerHasClosed() -> Bool {
        guard clientFD >= 0, !isClosed else { return true }
        var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
        let pres = poll(&pfd, 1, 0)
        if pres < 0 { return errno != EINTR }
        if pres == 0 { return false }
        if (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 { return true }
        var byte: UInt8 = 0
        let peeked = recv(clientFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if peeked == 0 { return true }
        if peeked < 0 { return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR }
        return false
    }

    /// True when a complete or partial frame is already waiting to be read.
    public func hasPendingMessage() -> Bool {
        guard clientFD >= 0, !isClosed else { return false }
        var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, 0) > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    /// Drops the current helper connection while keeping the listener open for
    /// the next browser-launched helper.
    public func dropClient() {
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
        peerPID = 0
    }

    /// Closes descriptors and unlinks only this session's private directory.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        unlink(config.socketPath)
        try? FileManager.default.removeItem(at: sessionDirectoryURL)
    }

    deinit {
        if clientFD >= 0 { Darwin.close(clientFD) }
        if serverFD >= 0 { Darwin.close(serverFD) }
    }
}

/// Client used by HaloNativeHost to authenticate with Halo over the local Unix Domain Socket.
public final class BridgeIPCClient: @unchecked Sendable {
    private let fd: Int32
    private let sessionNonce: String
    private let lock = NSLock()
    private var isClosed = false

    public init(sessionConfig: BridgeSessionConfig, origin: String, timeoutSeconds: TimeInterval = 5) throws {
        let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sfd >= 0 else {
            throw BridgeErrorDetails(code: .internalError, message: "Failed to create client socket: errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard sessionConfig.socketPath.utf8.count < maxPath else {
            Darwin.close(sfd)
            throw BridgeErrorDetails(code: .internalError, message: "Socket path is too long.")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), sessionConfig.socketPath, maxPath - 1)
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sfd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRes == 0 else {
            Darwin.close(sfd)
            throw BridgeErrorDetails(code: .internalError, message: "Failed to connect to Halo bridge socket: errno \(errno)")
        }

        // Send auth message
        let authMsg = BridgeHostAuthMessage(authToken: sessionConfig.authToken, clientPID: getpid(), origin: origin)
        let authData = try JSONEncoder().encode(authMsg)
        do {
            try BridgeSocketIO.writeFramedData(to: sfd, payload: authData, timeoutSeconds: timeoutSeconds)
            let respData = try BridgeSocketIO.readFramedData(from: sfd, timeoutSeconds: timeoutSeconds)
            let resp = try JSONDecoder().decode(BridgeHostAuthResponse.self, from: respData)
            guard resp.authenticated else {
                Darwin.close(sfd)
                throw BridgeErrorDetails(code: .authenticationFailed, message: "Halo rejected host authentication: \(resp.error ?? "unknown")")
            }
            self.sessionNonce = resp.sessionNonce
            self.fd = sfd
        } catch {
            Darwin.close(sfd)
            throw error
        }
    }

    public var establishedNonce: String { sessionNonce }

    /// Waits up to `timeoutSeconds` for the next frame to begin arriving. Returns
    /// true when data (or a hang-up) is ready, so idle connections never time out.
    public func waitUntilReadable(timeoutSeconds: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, Int32(timeoutSeconds * 1000)) > 0
    }

    public func readFramedPayload(timeoutSeconds: TimeInterval = 10) throws -> Data {
        try BridgeSocketIO.readFramedData(from: fd, timeoutSeconds: timeoutSeconds)
    }

    public func writeFramedPayload(_ payload: Data, timeoutSeconds: TimeInterval = 10) throws {
        try BridgeSocketIO.writeFramedData(to: fd, payload: payload, timeoutSeconds: timeoutSeconds)
    }

    /// Thread-safe, strictly idempotent descriptor closure.
    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(fd)
        }
    }

    deinit {
        close()
    }
}
