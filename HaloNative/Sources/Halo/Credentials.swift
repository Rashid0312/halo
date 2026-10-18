import Foundation
import Security

enum Credentials {
    private static let service = "app.halo.native.dev.providers"

    static func read(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ChatGPTFailure("Keychain access failed (\(status)).") }
        return result as? Data
    }

    static func write(account: String, data: Data?) throws {
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

    static func existingDeepSeekKey() -> String {
        existingProviderKey(account: "deepseek", environmentName: "DEEPSEEK_API_KEY")
    }

    static func existingDeepgramKey() -> String {
        existingProviderKey(account: "deepgram", environmentName: "DEEPGRAM_API_KEY")
    }
}
