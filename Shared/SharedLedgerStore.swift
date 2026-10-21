import Foundation
import Security

/// Keychain sharing survives ordinary app suspension. Signing must authorize the
/// same access group in BOTH targets; missing entitlements are an explicit error.
struct SharedLedgerStore {
    private let service = "FlowLedger.committed-snapshot.v1"
    private let account = "ledger"

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)
        case missingGroup
        var errorDescription: String? {
            switch self {
            case .missingGroup: return "无法识别签名的钥匙串共享组"
            case .keychain(let code): return "组件共享失败（\(code)），签名须保留共享钥匙串权限"
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

    private func sharedGroup() throws -> String {
        // The application identifier prefix is assigned by the signer, not
        // necessarily the developer's original team. Discover it at runtime.
        let probeService = "FlowLedger.signing-probe"
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
              let group = attributes[kSecAttrAccessGroup] as? String,
              let separator = group.firstIndex(of: "."),
              var bundleID = Bundle.main.bundleIdentifier else { throw Failure.missingGroup }
        if bundleID.hasSuffix(".widget") { bundleID.removeLast(".widget".count) }
        return String(group[...separator]) + bundleID
    }
}
