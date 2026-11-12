import Foundation
import Security

public protocol CredentialStore: Sendable {
    func credential(for profileID: UUID) throws -> ConnectionCredential?
    func setCredential(_ credential: ConnectionCredential?, for profileID: UUID) throws
}

public enum CredentialStoreError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// One generic-password item per connection profile, in this app's own
/// Keychain. Items are this-device-only and never synchronized.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "com.zacharysturman.cameramonitor.connection") {
        self.service = service
    }

    private func query(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }

    public func credential(for profileID: UUID) throws -> ConnectionCredential? {
        var query = query(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain(status) }
        return try JSONDecoder().decode(ConnectionCredential.self, from: data)
    }

    public func setCredential(_ credential: ConnectionCredential?, for profileID: UUID) throws {
        let base = query(for: profileID)
        guard let credential, !credential.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
            return
        }
        let data = try JSONEncoder().encode(credential)
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialStoreError.keychain(updateStatus) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }
}

/// For tests, previews and fixture runs.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var items: [UUID: ConnectionCredential] = [:]
    private let lock = NSLock()

    public init(_ items: [UUID: ConnectionCredential] = [:]) {
        self.items = items
    }

    public func credential(for profileID: UUID) throws -> ConnectionCredential? {
        lock.lock(); defer { lock.unlock() }
        return items[profileID]
    }

    public func setCredential(_ credential: ConnectionCredential?, for profileID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        items[profileID] = (credential?.isEmpty ?? true) ? nil : credential
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }
}
