import Foundation
import Security

/// Stores the Anthropic API key in the login keychain instead of the settings file.
public enum Keychain {
    private static let service = "me.jph.minutes"
    private static let account = "anthropic-api-key"

    /// Off for `--snapshot` renders and isolated test runs of the app: an unsigned binary's keychain read opens an
    /// access dialog that blocks until someone answers it. The key then comes only from ANTHROPIC_API_KEY.
    nonisolated(unsafe) public static var enabled = true

    public static func apiKey() -> String? {
        guard enabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the key. `trustedApps` (paths) may read it without a keychain prompt in addition to the caller:
    /// the CLI passes the app here, so a key stored from the terminal does not trigger an access dialog in the app.
    @discardableResult
    public static func setAPIKey(_ key: String?, trustedApps: [String] = []) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "Minutes – Anthropic API key"
        if !trustedApps.isEmpty, let access = makeAccess(trustedApps) { add[kSecAttrAccess as String] = access }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Legacy keychain ACL (deprecated API, still the only way to pre-authorize another app for a login-keychain item).
    private static func makeAccess(_ paths: [String]) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        for path in paths {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        guard SecAccessCreate("Minutes – Anthropic API key" as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    /// Set by the CLI: it uses only ANTHROPIC_API_KEY (environment or ./.env), because reading the app's keychain
    /// item from another binary opens an access dialog that blocks the command.
    nonisolated(unsafe) public static var environmentOnly = false

    /// The key entered in Settings (keychain, encrypted on disk) wins over the ANTHROPIC_API_KEY environment
    /// variable, which is only a fallback.
    public static func resolvedAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        if environmentOnly { return env }
        if let key = apiKey(), !key.isEmpty { return key }
        return env
    }

    /// Whether notes can be written at all (a key in Settings or in the environment).
    public static var hasKey: Bool { resolvedAPIKey() != nil }
}
