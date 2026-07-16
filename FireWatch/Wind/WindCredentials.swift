import Foundation
import Security

// Synoptic Data token access. The token never lives in the repo: it is read, in
// priority order, from (1) the SYNOPTIC_TOKEN environment variable (useful for
// Xcode scheme runs), (2) the login keychain, (3) UserDefaults (settable from
// Terminal with `defaults write com.finlaybennett.FireWatch synopticToken …`,
// the zero-friction path for a personal tool).
//
// A free token comes from Synoptic's Open Access program:
// https://synopticdata.com/open-access-program/

enum WindCredentials {
    private static let keychainService = "com.finlaybennett.FireWatch"
    private static let keychainAccount = "SYNOPTIC_TOKEN"
    private static let defaultsKey = "synopticToken"

    /// The Synoptic token, if configured anywhere. Nil means "use NWS fallback".
    static func synopticToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["SYNOPTIC_TOKEN"],
           !env.isEmpty { return env }
        if let keychain = readKeychain(), !keychain.isEmpty { return keychain }
        if let defaults = UserDefaults.standard.string(forKey: defaultsKey),
           !defaults.isEmpty { return defaults }
        return nil
    }

    /// Store the token in the login keychain (replacing any existing value).
    @discardableResult
    static func setSynopticToken(_ token: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
