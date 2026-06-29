//
//  CookieLoader.swift
//  Squirrel
//
//  Ported from LizardType (Sources/Bridge/CookieLoader.swift).
//  Parses a Cookie-Editor style `cookies.json` export into `HTTPCookie`s, and
//  hosts `SessionStore` — the Keychain-free persistence used for web-session
//  cookies and the Groq key (SPEC §4.8).
//

import Foundation
import WebKit

extension WKHTTPCookieStore {
  /// Continuation wrapper for `getAllCookies` — the bare async overload doesn't
  /// resolve from the bridges' `@MainActor` static context (the compiler only
  /// sees the completion-handler form), so call this instead.
  func cookiesSnapshot() async -> [HTTPCookie] {
    await withCheckedContinuation { cont in
      getAllCookies { cont.resume(returning: $0) }
    }
  }
}

enum CookieLoader {
  struct Entry: Codable {
    let domain: String
    let name: String
    let value: String
    let path: String?
    let secure: Bool?
    let httpOnly: Bool?
    let expirationDate: Double?
    let session: Bool?
  }

  enum LoadError: LocalizedError {
    case unreadable(String)
    case unparseable
    var errorDescription: String? {
      switch self {
      case .unreadable(let p): return "Can't read cookies file at \(p)"
      case .unparseable: return "cookies.json is not in the expected format"
      }
    }
  }

  /// Returns cookies scoped to `domainSuffix` (default chatgpt.com for the
  /// ChatGPT bridge; pass "google.com" for the Gemini web bridge). Skips ws.*
  /// subdomains we don't navigate.
  static func load(from path: String, domainSuffix: String = "chatgpt.com") throws -> [HTTPCookie] {
    guard let data = FileManager.default.contents(atPath: path) else {
      throw LoadError.unreadable(path)
    }
    guard let cookies = cookies(from: data, domainSuffix: domainSuffix) else {
      throw LoadError.unparseable
    }
    return cookies
  }

  /// Decode a Cookie-Editor style JSON blob into domain-scoped `HTTPCookie`s.
  /// Used both for legacy `cookies.json` files and for the self-managed session
  /// store (SPEC §4.8). Returns nil only when the JSON itself is malformed.
  static func cookies(from data: Data, domainSuffix: String) -> [HTTPCookie]? {
    guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
    return entries.compactMap { entry in
      // Only cookies scoped to the target domain; skip ws.* (not navigated).
      guard entry.domain.hasSuffix(domainSuffix), !entry.domain.hasPrefix("ws") else { return nil }
      var props: [HTTPCookiePropertyKey: Any] = [
        .name: entry.name,
        .value: entry.value,
        .domain: entry.domain,
        .path: entry.path ?? "/"
      ]
      if entry.secure == true { props[.secure] = "TRUE" }
      if let exp = entry.expirationDate, entry.session != true {
        props[.expires] = Date(timeIntervalSince1970: exp)
      }
      return HTTPCookie(properties: props)
    }
  }

  /// Serialize live cookies (scoped to `domainSuffix`) back to the Cookie-Editor
  /// JSON shape `cookies(from:)` reads. Used to snapshot a logged-in web session
  /// to the self-managed store.
  static func serialize(_ cookies: [HTTPCookie], domainSuffix: String) -> Data {
    let entries = cookies
      .filter { $0.domain.hasSuffix(domainSuffix) && !$0.domain.hasPrefix("ws") }
      .map { c in
        Entry(domain: c.domain, name: c.name, value: c.value, path: c.path,
              secure: c.isSecure, httpOnly: c.isHTTPOnly,
              expirationDate: c.expiresDate?.timeIntervalSince1970, session: c.isSessionOnly)
      }
    return (try? JSONEncoder().encode(entries)) ?? Data()
  }

  /// Best-effort device id from the `oai-did` cookie (used as oai-device-id header).
  static func deviceId(from path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
    return entries.first(where: { $0.name == "oai-did" })?.value
  }
}

/// Keychain-free persistence for web-session cookies and the Groq key (SPEC §4.8).
///
/// Replaces WebKit's identifier-based persistent `WKWebsiteDataStore`, which
/// stores its store-encryption key in the login Keychain. Under Squirrel's
/// ad-hoc signing + re-sign-on-install, the Keychain ACL is bound to a cdhash
/// that changes on every re-sign, so each access pops the "Squirrel wants to use
/// your confidential information" prompt. Files here live under
/// `~/Library/Application Support/Squirrel/` with `0600` perms — protection is
/// filesystem-only (the chosen reliability-first tradeoff: zero prompt and
/// re-sign immunity, since Keychain is incompatible with no-prompt under ad-hoc
/// signing).
enum SessionStore {
  /// `~/Library/Application Support/Squirrel/`, created `0700` on first use.
  static func directory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let dir = base.appendingPathComponent("Squirrel", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return dir
  }

  private static func url(_ name: String) -> URL { directory().appendingPathComponent(name) }

  static func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

  /// Write owner-only (`0600`). Atomic replace can reset perms, so re-apply after.
  static func write(_ data: Data, to name: String) {
    let u = url(name)
    do {
      try data.write(to: u, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    } catch {
      NSLog("[SessionStore] write %@ failed: %@", name, error.localizedDescription)
    }
  }

  static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

  static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

  // MARK: Cookies

  static func loadCookies(file: String, domainSuffix: String) -> [HTTPCookie]? {
    guard let data = read(file) else { return nil }
    return CookieLoader.cookies(from: data, domainSuffix: domainSuffix)
  }

  static func saveCookies(_ cookies: [HTTPCookie], domainSuffix: String, file: String) {
    write(CookieLoader.serialize(cookies, domainSuffix: domainSuffix), to: file)
  }

  // MARK: Plain string secrets (Groq key)

  static func string(_ name: String) -> String? {
    guard let data = read(name), let s = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func setString(_ value: String, name: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { remove(name) }
    else if let data = trimmed.data(using: .utf8) { write(data, to: name) }
  }
}
