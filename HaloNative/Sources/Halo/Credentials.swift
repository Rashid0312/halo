import Foundation
import Security

enum Credentials {
    private static let service = "app.halo.native.dev.providers"

    /// Development builds are signed without an Apple Team ID, so macOS ties
    /// Keychain access to each build's binary hash and prompts for the login
    /// password after every rebuild. They keep credentials in files readable
    /// only by this user instead; release builds use the Keychain.
    static var isDevelopmentBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HaloDevelopmentEnvFile") is String
    }

    private static var developmentStore: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/app.halo.native.dev/credentials", isDirectory: true)
    }

    private static func developmentFile(_ account: String) -> URL {
        developmentStore.appendingPathComponent(account)
    }

    static func read(account: String) throws -> Data? {
        guard isDevelopmentBuild else { return try readKeychain(account: account) }
        if let data = try? Data(contentsOf: developmentFile(account)) { return data }
        // One-time move of a value saved by an earlier build (one last prompt).
        guard let migrated = try readKeychain(account: account) else { return nil }
        try writeDevelopmentFile(account: account, data: migrated)
        return migrated
    }

    static func write(account: String, data: Data?) throws {
        guard isDevelopmentBuild else { return try writeKeychain(account: account, data: data) }
        try writeDevelopmentFile(account: account, data: data)
    }

    private static func writeDevelopmentFile(account: String, data: Data?) throws {
        let file = developmentFile(account)
        guard let data else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: developmentStore, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func readKeychain(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ChatGPTFailure("Keychain access failed (\(status)).") }
        return result as? Data
    }

    private static func writeKeychain(account: String, data: Data?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTFailure("Could not delete saved credentials.") }
            return
        }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ChatGPTFailure("Could not update saved credentials.") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ChatGPTFailure("Could not save credentials to Keychain.") }
    }

    /// Imports only the requested existing development key, never logging its value.
    private static func existingProviderKey(account: String, environmentName: String) -> String {
        // Development builds read the development .env file and never touch the
        // Keychain (see isDevelopmentBuild).
        if isDevelopmentBuild {
            return developmentEnvironmentValue(environmentName)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty { return key }

        var key = ProcessInfo.processInfo.environment[environmentName] ?? ""
        if key.isEmpty, let file = Bundle.main.object(forInfoDictionaryKey: "HaloDevelopmentEnvFile") as? String,
           let contents = try? String(contentsOfFile: file, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines) {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
                guard name == environmentName else { continue }
                key = pair[1].trimmingCharacters(in: .whitespaces)
                if key.count >= 2, (key.first == "\"" && key.last == "\"") || (key.first == "'" && key.last == "'") {
                    key = String(key.dropFirst().dropLast())
                }
                break
            }
        }
        guard !key.isEmpty else { return "" }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // A failed save does not prevent using the existing development key this session.
        SecItemAdd(item as CFDictionary, nil)
        return key
    }

    private static func developmentEnvironmentValue(_ environmentName: String) -> String {
        if let value = ProcessInfo.processInfo.environment[environmentName], !value.isEmpty { return value }
        guard let file = Bundle.main.object(forInfoDictionaryKey: "HaloDevelopmentEnvFile") as? String,
              let contents = try? String(contentsOfFile: file, encoding: .utf8) else { return "" }
        for line in contents.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
            guard name == environmentName else { continue }
            var key = pair[1].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, (key.first == "\"" && key.last == "\"") || (key.first == "'" && key.last == "'") {
                key = String(key.dropFirst().dropLast())
            }
            return key
        }
        return ""
    }

    static func existingDeepSeekKey() -> String {
        existingProviderKey(account: "deepseek", environmentName: "DEEPSEEK_API_KEY")
    }

    static func existingDeepgramKey() -> String {
        existingProviderKey(account: "deepgram", environmentName: "DEEPGRAM_API_KEY")
    }
}
