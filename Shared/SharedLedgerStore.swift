import Foundation
import Security

/// Keychain sharing survives ordinary app suspension. Signing must authorize the
/// same access group in BOTH targets; missing entitlements are an explicit error.
struct SharedLedgerStore {
    private let service = "FlowLedger.committed-snapshot.v1"
    private let account = "ledger"
    private let applicationBundleIdentifier: String?

    init(applicationBundleIdentifier: String? = nil) {
        self.applicationBundleIdentifier = applicationBundleIdentifier
    }

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)
        case missingGroup
        var errorDescription: String? {
            switch self {
            case .missingGroup: return "无法识别签名的钥匙串共享组"
            case .keychain(errSecMissingEntitlement): return "当前签名未授权组件共享（-34018）"
            case .keychain(errSecInteractionNotAllowed): return "共享账本暂不可读，请解锁手机后重试"
            case .keychain(let code): return "组件共享失败（\(code)）"
            }
        }
    }

    func write(_ snapshot: LedgerSnapshot) throws {
        let query = try itemQuery()
        let data = try JSONEncoder().encode(snapshot)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw Failure.keychain(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(try itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    func read() throws -> LedgerSnapshot? {
        var query = try itemQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data else { throw Failure.missingGroup }
        return try JSONDecoder().decode(LedgerSnapshot.self, from: data)
    }

    private func itemQuery() throws -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account,
         kSecAttrAccessGroup: try sharedGroup()]
    }

    func sharedGroup() throws -> String {
        // Read an actually accessible group, rather than guessing permission
        // from a team prefix. Some enterprise re-signers replace BOTH targets'
        // groups with the same literal wildcard or a different app identity.
        // A wildcard in the signed entitlement is not permission for an
        // arbitrary group formed from our original bundle identifier.
        guard let bundleID = applicationBundleIdentifier ?? Bundle.main.bundleIdentifier else {
            throw Failure.missingGroup
        }
        let rootID = Self.rootBundleIdentifier(bundleID)
        let probeService = "FlowLedger.signing-probe.v2.\(rootID)"
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: probeService,
                                     kSecAttrAccount: "prefix",
                                     kSecReturnAttributes: true]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            query[kSecValueData] = Data([0])
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, &result)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let attributes = result as? [CFString: Any],
              let group = attributes[kSecAttrAccessGroup] as? String else { throw Failure.missingGroup }
        return try Self.resolveSharedGroup(defaultGroup: group, bundleIdentifier: bundleID)
    }

    static func rootBundleIdentifier(_ bundleID: String) -> String {
        bundleID.hasSuffix(".widget") ? String(bundleID.dropLast(".widget".count)) : bundleID
    }

    static func resolveSharedGroup(defaultGroup: String, bundleIdentifier: String) throws -> String {
        guard let separator = defaultGroup.firstIndex(of: "."),
              separator != defaultGroup.startIndex,
              defaultGroup.index(after: separator) != defaultGroup.endIndex,
              defaultGroup != "com.apple.token", !bundleIdentifier.isEmpty else {
            throw Failure.missingGroup
        }
        let prefix = String(defaultGroup[...separator])
        if defaultGroup == prefix + bundleIdentifier {
            // Standard signing: the widget has its own default group plus the
            // explicit parent group supplied in NetFlowWidget.entitlements.
            return prefix + rootBundleIdentifier(bundleIdentifier)
        }
        // Re-signing: keep the exact accessible group (including a literal '*').
        // App and widget must still be granted the same group by their signer;
        // no sandbox path fallback or invented entitlement is used here.
        return defaultGroup
    }
}
