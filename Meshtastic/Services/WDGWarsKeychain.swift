//
//  WDGWarsKeychain.swift
//
//  Stores the WDGWars API key in the keychain instead of UserDefaults.
//

import Foundation
import Security

enum WDGWarsKeychain {
	private static let service = "wdgwars.api-key"
	private static let account = "default"
	private static let legacyDefaultsKey = "wdgwarsApiKey"

	private static var query: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: account]
	}

	static func load() -> String {
		migrateLegacyKey()
		var q = query
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
			  let data = item as? Data else { return "" }
		return String(decoding: data, as: UTF8.self)
	}

	static func save(_ key: String) {
		let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
		SecItemDelete(query as CFDictionary)
		guard !trimmed.isEmpty else { return }
		var q = query
		q[kSecValueData as String] = Data(trimmed.utf8)
		q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		SecItemAdd(q as CFDictionary, nil)
	}

	/// Moves a key saved by an earlier build out of UserDefaults.
	private static func migrateLegacyKey() {
		let defaults = UserDefaults.standard
		guard let old = defaults.string(forKey: legacyDefaultsKey) else { return }
		defaults.removeObject(forKey: legacyDefaultsKey)
		var q = query
		q[kSecReturnData as String] = false
		if !old.isEmpty, SecItemCopyMatching(q as CFDictionary, nil) != errSecSuccess {
			save(old)
		}
	}
}
