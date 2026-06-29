//
//  GroqSecrets.swift
//  Squirrel
//
//  Ported from LizardType (Sources/Bridge/GroqSecrets.swift).
//  Resolves and persists the Groq API key.
//
//  Lookup order (first hit wins):
//    1. SessionStore file — written from the Settings UI (SPEC §4.8). Stored
//       outside the Keychain so re-signing on install never triggers a Keychain
//       prompt. One-time migration imports a pre-existing Keychain key.
//    2. `GROQ_API_KEY` process environment variable.
//    3. `.env` file (`KEY=VALUE`) in `~/Library/Rime/`, then `$HOME`.
//       Accepts `GROQ_API_KEY` or `GROQ_API`.
//

import Foundation
import Security

enum GroqSecrets {
  private static let service = "rime.squirrel.groq"
  private static let account = "api-key"
  private static let storeFile = "groq-api-key"

  /// The effective key from any source, or nil if none is available.
  static func apiKey() -> String? {
    if let k = storedKey(), !k.isEmpty { return k }
    if let k = environmentKey(), !k.isEmpty { return k }
    return nil
  }

  /// True if a key exists outside the managed store (env / .env) — used by the UI
  /// to tell the user a key was auto-detected even though the field is empty.
  static func hasEnvKey() -> Bool {
    (environmentKey()?.isEmpty == false)
  }

  /// The key currently in the self-managed store (the editable Settings value).
  /// Migrates a legacy Keychain key into the store on first read, then drops the
  /// Keychain item so it stops prompting.
  static func storedKey() -> String? {
    if let k = SessionStore.string(storeFile) { return k }
    if let migrated = migrateKeychainKey() { return migrated }
    return nil
  }

  /// Write (or clear, when empty) the key in the self-managed store.
  static func setStoredKey(_ key: String) {
    SessionStore.setString(key, name: storeFile)
  }

  // MARK: - Legacy Keychain migration

  /// One-time import of a key written by an older build into the Keychain. Reads
  /// it once (prompts once for users who had one), copies to the store, then
  /// deletes the Keychain item so it never prompts again. No item → no prompt.
  private static func migrateKeychainKey() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let s = String(data: data, encoding: .utf8),
          !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    setStoredKey(s)
    SecItemDelete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ] as CFDictionary)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Environment / .env

  private static func environmentKey() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let k = env["GROQ_API_KEY"], !k.isEmpty { return k }
    if let k = env["GROQ_API"], !k.isEmpty { return k }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // cwd is SharedSupport inside the app bundle (set in Main.swift), so look
    // in the Rime user dir and $HOME instead of the working directory.
    let candidates = [
      home + "/Library/Rime/.env",
      home + "/.env"
    ]
    for path in candidates {
      if let k = parseEnvFile(path) { return k }
    }
    return nil
  }

  /// Minimal `.env` parser: returns the value of GROQ_API_KEY / GROQ_API.
  private static func parseEnvFile(_ path: String) -> String? {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let name = line[..<eq].trimmingCharacters(in: .whitespaces)
      guard name == "GROQ_API_KEY" || name == "GROQ_API" else { continue }
      var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      // Strip surrounding quotes.
      if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
        value = String(value.dropFirst().dropLast())
      }
      if !value.isEmpty { return value }
    }
    return nil
  }
}
