import Foundation
import Security

enum Credentials {
    private static let service = "app.halo.native.dev.providers"

    /// Imports only the requested existing development key, never logging its value.
    static func existingDeepSeekKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deepseek",
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty { return key }

        var key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ""
        if key.isEmpty, let file = Bundle.main.object(forInfoDictionaryKey: "HaloDevelopmentEnvFile") as? String,
           let contents = try? String(contentsOfFile: file, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines) {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
                guard name == "DEEPSEEK_API_KEY" else { continue }
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
}
