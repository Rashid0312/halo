import Foundation
import Darwin
import HaloBridge

private func logDiagnostic(_ message: String) {
    fputs("[HaloNativeHost] \(message)\n", stderr)
    fflush(stderr)
}

// 1. Validate invocation arguments and options
var customSessionDir: URL? = nil
var originArg: String? = nil

var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    if arg == "--session-dir" && i + 1 < CommandLine.arguments.count {
        customSessionDir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        i += 2
    } else if arg.hasPrefix("chrome-extension://") {
        originArg = arg
        i += 1
    } else {
        i += 1
    }
}

guard let origin = originArg else {
    logDiagnostic("Error: Expected chrome-extension:// origin in arguments.")
    exit(1)
}

// 2. Locate and validate active session configuration
let sessionFile = BridgeSessionConfig.defaultSessionFile(in: customSessionDir)
guard FileManager.default.fileExists(atPath: sessionFile.path) else {
    logDiagnostic("Error: No active Halo bridge session file found at \(sessionFile.path).")
    exit(1)
}

let sessionData: Data
do {
    sessionData = try Data(contentsOf: sessionFile)
} catch {
    logDiagnostic("Error: Failed to read session configuration: \(error.localizedDescription)")
    exit(1)
}

guard let sessionConfig = try? JSONDecoder().decode(BridgeSessionConfig.self, from: sessionData) else {
    logDiagnostic("Error: Malformed session configuration file.")
    exit(1)
}

guard abs(Date().timeIntervalSince(sessionConfig.createdAt)) <= 60 else {
    logDiagnostic("Error: Session configuration expired.")
    exit(1)
}

// 3. Connect to Halo's peer-authenticated Unix Domain Socket
let client: BridgeIPCClient
do {
    client = try BridgeIPCClient(sessionConfig: sessionConfig, origin: origin)
    logDiagnostic("Authenticated with Halo session successfully.")
} catch {
    logDiagnostic("Error: Failed to authenticate with Halo: \(error.localizedDescription)")
    exit(1)
}

// Ignore SIGPIPE so broken pipes yield EPIPE / clean EOF instead of process crash
signal(SIGPIPE, SIG_IGN)

private actor HostState {
    private var isTerminating = false

    func terminate() {
        isTerminating = true
    }

    func shouldTerminate() -> Bool {
        isTerminating
    }
}

private let hostState = HostState()

let stdinTask = Task.detached(priority: .userInitiated) {
    defer {
        Task { await hostState.terminate() }
        client.close()
    }
    let stdinFD = fileno(stdin)
    while !(await hostState.shouldTerminate()) {
        var lenBytes = [UInt8](repeating: 0, count: 4)
        var totalRead = 0
        while totalRead < 4 {
            let r = read(stdinFD, &lenBytes[totalRead], 4 - totalRead)
            if r == 0 {
                logDiagnostic("Chromium Native Messaging stdin closed (EOF).")
                return
            } else if r < 0 {
                if errno == EINTR { continue }
                logDiagnostic("Error reading from stdin: errno \(errno)")
                return
            }
            totalRead += r
        }

        let declared = lenBytes.enumerated().reduce(UInt32(0)) { partial, pair in
            partial | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }

        guard declared <= UInt32(BrowserBridgeLimits.maxMessageSizeBytes) else {
            logDiagnostic("Fatal error: Declared frame length \(declared) exceeds max limit of \(BrowserBridgeLimits.maxMessageSizeBytes) bytes.")
            exit(1)
        }

        var payload = Data(count: Int(declared))
        var payloadRead = 0
        var readFailed = false
        while payloadRead < Int(declared) {
            let r = payload.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return read(stdinFD, base.advanced(by: payloadRead), Int(declared) - payloadRead)
            }
            if r == 0 {
                logDiagnostic("Unexpected EOF reading frame payload from stdin.")
                readFailed = true
                break
            } else if r < 0 {
                if errno == EINTR { continue }
                logDiagnostic("Error reading payload from stdin: errno \(errno)")
                readFailed = true
                break
            }
            payloadRead += r
        }
        if readFailed { break }

        // Forward to Halo IPC
        do {
            try client.writeFramedPayload(payload)
        } catch {
            logDiagnostic("Error forwarding message to Halo IPC: \(error.localizedDescription)")
            break
        }
    }
}

let ipcTask = Task.detached(priority: .userInitiated) {
    defer {
        Task { await hostState.terminate() }
    }
    let stdoutFD = fileno(stdout)
    while !(await hostState.shouldTerminate()) {
        // An idle bridge is healthy: wait without a deadline for the next frame,
        // waking each second to notice termination, then bound the frame read.
        guard client.waitUntilReadable(timeoutSeconds: 1) else { continue }
        let payload: Data
        do {
            payload = try client.readFramedPayload(timeoutSeconds: 10)
        } catch {
            if !(await hostState.shouldTerminate()) {
                logDiagnostic("Halo IPC read ended or timed out: \(error.localizedDescription)")
            }
            break
        }

        guard payload.count <= BrowserBridgeLimits.maxMessageSizeBytes else {
            logDiagnostic("Fatal error: Payload from Halo exceeds max message size.")
            break
        }

        var declared = UInt32(payload.count).littleEndian
        var header = withUnsafeBytes(of: &declared) { Data($0) }
        header.append(payload)

        var totalWritten = 0
        let bytes = Array(header)
        var writeFailed = false
        while totalWritten < bytes.count {
            let w = bytes.withUnsafeBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return write(stdoutFD, base.advanced(by: totalWritten), bytes.count - totalWritten)
            }
            if w <= 0 {
                if errno == EINTR { continue }
                logDiagnostic("Error writing to stdout: errno \(errno)")
                writeFailed = true
                break
            }
            totalWritten += w
        }
        if writeFailed { break }
        fflush(stdout)
    }
}

// The Halo socket bounds the helper's lifetime. Stdin EOF closes the client,
// which also ends the IPC task; Halo closing the socket ends it directly while
// stdin may still be blocked in read(), so do not wait for the stdin task.
_ = stdinTask
_ = await ipcTask.result
await hostState.terminate()
client.close()
logDiagnostic("HaloNativeHost terminated cleanly.")
exit(0)
