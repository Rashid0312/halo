import Foundation
import Observation
import Darwin
import HaloBridge

/// Explicit opt-in lifecycle for the read-only Chromium Native Messaging bridge.
/// While enabled, Halo publishes a host manifest for installed Chromium browsers,
/// waits for the browser-launched helper, completes the pinned-extension
/// handshake, and attaches the connection to `ChromeBrowserService`. Disabling,
/// quitting, or losing the helper detaches it; disabling also removes every
/// manifest and the private session directory.
@MainActor @Observable
final class BrowserBridgeController {
    static let developmentExtensionID = "mfnoiamhnajnnieagdpagkebabpnkdmc"
    static let hostName = "app.halo.browser_bridge"
    /// The helper rejects session files older than 60s; rotate well before that.
    static let credentialRotationSeconds: TimeInterval = 30

    enum Status: Equatable {
        case off
        case waiting
        case connected(announcedTabs: Int)
        case failed(String)

        var summary: String {
            switch self {
            case .off: "Off. No browser can reach Halo."
            case .waiting: "Waiting for the Halo extension to connect."
            case .connected(let tabs): "Connected. \(tabs) eligible tab\(tabs == 1 ? "" : "s") announced."
            case .failed(let reason): "Unavailable: \(reason)"
            }
        }
    }

    private(set) var status: Status = .off
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: "browserBridgeEnabled")
            enabled ? start() : stop()
        }
    }

    /// Tabs the extension announced during the latest handshake.
    @ObservationIgnored private(set) var announcements: [BridgeTabAnnouncement] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let service: ChromeBrowserService
    @ObservationIgnored private let helperURL: URL
    @ObservationIgnored private let manifestDirectories: () -> [URL]
    @ObservationIgnored private var server: BridgeIPCServer?
    @ObservationIgnored private var manifests: [URL] = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(
        service: ChromeBrowserService = .shared,
        helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/HaloNativeHost"),
        manifestDirectories: @escaping () -> [URL] = BrowserBridgeController.installedBrowserManifestDirectories,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: "browserBridgeEnabled")
        self.service = service
        self.helperURL = helperURL
        self.manifestDirectories = manifestDirectories
    }

    /// Restores the persisted opt-in after launch.
    func resumeIfEnabled() {
        if enabled { start() }
    }

    /// Native host directories for Chromium browsers that have a user profile.
    nonisolated static func installedBrowserManifestDirectories() -> [URL] {
        NativeMessagingInstaller.defaultManifestDirectories().filter {
            FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path)
        }
    }

    private func start() {
        guard loop == nil else { return }
        BridgeSessionConfig.removeAbandonedSessionDirectories()
        do {
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                throw BridgeErrorDetails(code: .internalError, message: "HaloNativeHost is missing from the app bundle.")
            }
            let directories = manifestDirectories()
            guard !directories.isEmpty else {
                throw BridgeErrorDetails(code: .internalError, message: "No supported Chromium browser profile was found.")
            }
            let server = try BridgeIPCServer(pinnedExtensionID: Self.developmentExtensionID, helperExecutableURL: helperURL)
            guard let launcher = server.launcherURL else {
                Task { await server.close() }
                throw BridgeErrorDetails(code: .internalError, message: "Bridge server did not create its launcher.")
            }
            do {
                manifests = try NativeMessagingInstaller.install(
                    hostName: Self.hostName,
                    launcherPath: launcher.path,
                    allowedOrigins: ["chrome-extension://\(Self.developmentExtensionID)/"],
                    targetDirectories: directories
                )
            } catch {
                Task { await server.close() }
                throw error
            }
            self.server = server
            status = .waiting
            loop = Task { [weak self] in await self?.run(server) }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        let loop = self.loop, server = self.server, manifests = self.manifests
        self.loop = nil
        self.server = nil
        self.manifests = []
        loop?.cancel()
        NativeMessagingInstaller.uninstall(manifestURLs: manifests)
        status = .off
        Task { [service] in
            _ = await loop?.value
            await service.detachBridgeServer()
            await server?.close()
        }
    }

    /// Synchronous cleanup for app termination: no manifest may outlive Halo.
    func shutdownForTermination() {
        loop?.cancel()
        NativeMessagingInstaller.uninstall(manifestURLs: manifests)
        manifests = []
        if let server {
            try? FileManager.default.removeItem(at: server.directoryURL)
        }
        server = nil
    }

    private func run(_ server: BridgeIPCServer) async {
        while !Task.isCancelled {
            do {
                if await server.credentialAge >= Self.credentialRotationSeconds {
                    try await server.rotateCredentials()
                }
                try await server.acceptConnection(timeoutSeconds: 2)
            } catch {
                continue
            }

            do {
                let tabs = try await Self.performHandshake(server: server, pinnedExtensionID: Self.developmentExtensionID)
                await service.attachBridgeServer(server)
                announcements = tabs
                status = .connected(announcedTabs: tabs.count)
            } catch {
                await server.dropClient()
                try? await server.rotateCredentials()
                continue
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if await server.peerHasClosed() { break }
            }
            // A new helper means a new extension worker or browser whose document
            // generations restart; nothing authorized before may carry over.
            await service.detachBridgeServer()
            await service.revokeAll()
            announcements = []
            await server.dropClient()
            try? await server.rotateCredentials()
            if !Task.isCancelled { status = .waiting }
        }
    }

    /// Challenges a freshly authenticated helper, validates the pinned extension's
    /// channel binding, and collects the tab announcements that follow it.
    nonisolated static func performHandshake(
        server: BridgeIPCServer,
        pinnedExtensionID: String,
        announcementTimeout: TimeInterval = 1
    ) async throws -> [BridgeTabAnnouncement] {
        let challenge = BridgeHandshakeChallenge(serverNonce: server.sessionConfig.sessionNonce, hostProcessID: getpid())
        try await server.sendMessage(challenge)
        let envelope = try await server.receiveResponse(timeoutSeconds: 10)
        guard let handshake = envelope.handshake else {
            throw BridgeErrorDetails(code: .authenticationFailed, message: "Extension did not return a handshake response.")
        }
        try BridgeHandshakeValidator.validate(challenge: challenge, response: handshake, pinnedExtensionID: pinnedExtensionID)

        var announcements: [BridgeTabAnnouncement] = []
        var timeout = announcementTimeout
        while let next = try? await server.receiveResponse(timeoutSeconds: timeout) {
            guard BridgeSessionValidator.constantTimeEquals(next.sessionNonce, server.sessionConfig.sessionNonce),
                  let announced = next.tabAnnouncement else {
                throw BridgeErrorDetails(code: .payloadMalformed, message: "Unexpected message during tab announcement.")
            }
            announcements.append(announced)
            timeout = 0.3
        }
        return announcements
    }
}
