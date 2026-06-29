//
//  GeminiWebBridge.swift
//  Squirrel
//
//  Ported from lizardtype-gemini (Sources/Bridge/GeminiWebBridge.swift), extended
//  with a persistent WKWebsiteDataStore so a login performed in the Settings UI
//  survives restarts (mirrors ChatGPTBridge, SPEC §14.5), and with the transcribe
//  model/prompt and the request language threaded through parameters instead of
//  read from AppSettings.
//
//  Drives Gemini's web endpoints from inside a warmed, logged-in WKWebView so
//  requests run on the real `gemini.google.com` origin (cookies + CORS inherited
//  from the page). This is the cookie / web-session counterpart to ChatGPTBridge,
//  for users with a Gemini subscription but no API key.
//
//  ⚠️ Unlike ChatGPT, the Gemini web app has no clean `/transcribe` endpoint — it
//  uses an obfuscated `batchexecute` / `StreamGenerate` RPC. The request envelope
//  (`f.req`) and the response nesting are reverse-engineered and VERSION-FRAGILE;
//  they are the first things to re-verify if this provider stops working (read
//  `lastRawResponse` / the Settings diagnostics area).
//
//  Flow:
//    persistent session (UI login) or google.com cookies → load gemini.google.com/app
//    → scrape SNlM0e (at) + cfb2h (bl)
//    → upload audio to content-push.googleapis.com → StreamGenerate(prompt + file)
//    → StreamGenerate(cleanup prompt + raw)   [second pass, optional]
//

import Foundation
import WebKit

@MainActor
final class GeminiWebBridge: NSObject, WKNavigationDelegate, SpeechProvider {

  enum BridgeError: LocalizedError {
    case notReady
    case noAccount                 // session expired / cookies invalid (no SNlM0e)
    case upload(Int, String)
    case http(Int, String)
    case badResponse(String)
    var errorDescription: String? {
      switch self {
      case .notReady:             return "Gemini bridge not ready (page still loading)"
      case .noAccount:            return "Not logged in to Gemini — sign in from Voice Settings"
      case .upload(let c, let b): return "Gemini upload HTTP \(c): \(b)"
      case .http(let c, let b):   return "Gemini HTTP \(c): \(b)"
      case .badResponse(let s):   return "Unexpected Gemini response: \(s)"
      }
    }
  }

  static let domainSuffix = "google.com"
  private static let sessionFile = "gemini-session.json"

  /// One in-memory data store shared by the bridge and the Settings login
  /// WebView (in-process login visibility). Cross-restart persistence is the
  /// self-managed `SessionStore` cookie file, not WebKit's Keychain-backed
  /// identifier store — see SPEC §4.8 (Keychain prompts under ad-hoc signing).
  private static let sharedStore = WKWebsiteDataStore.nonPersistent()
  static func sessionDataStore() -> WKWebsiteDataStore { sharedStore }

  /// Snapshot the logged-in google.com cookies from the shared store to disk.
  static func persistSharedSession() async {
    let cookies = await sharedStore.httpCookieStore.cookiesSnapshot()
    SessionStore.saveCookies(cookies, domainSuffix: domainSuffix, file: sessionFile)
  }

  let webView: WKWebView
  private(set) var isReady = false
  private var readyWaiters: [CheckedContinuation<Void, Never>] = []

  private var lastActivity = Date()
  private var lastReload = Date()

  /// Last raw StreamGenerate body when a parse fails — surfaced in the Settings
  /// status so the parse path can be corrected without a rebuild when Google
  /// changes the envelope.
  private(set) var lastRawResponse = ""

  /// Process-wide last StreamGenerate diagnostic (status + parsed/raw). The
  /// Settings window and the transcription bridge live in the same Squirrel
  /// process, so the UI reads this to show what the *actual* transcribe call
  /// returned (success or the raw body to fix the parse path). SPEC §4.4b.
  @MainActor static var lastDiagnostic = ""

  override init() {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = GeminiWebBridge.sessionDataStore()
    webView = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: cfg)
    super.init()
    webView.navigationDelegate = self
  }

  // MARK: - Lifecycle

  /// Warm the bridge. If `cookiesPath` is non-empty, inject the exported
  /// google.com cookies first (legacy path); otherwise rely on the persistent
  /// session established via the Settings UI login. Safe to call again.
  func start(cookiesPath: String) async throws {
    isReady = false
    let store = webView.configuration.websiteDataStore.httpCookieStore
    if !cookiesPath.isEmpty {
      let cookies = try CookieLoader.load(from: cookiesPath, domainSuffix: Self.domainSuffix)
      for c in cookies { await store.setCookie(c) }
    } else {
      await restoreSessionIfNeeded(into: store)
    }
    webView.load(URLRequest(url: URL(string: "https://gemini.google.com/app")!))
  }

  /// Seed the shared store from the self-managed session file on a cold process.
  /// No-op once a google.com session is present, so a UI login is never clobbered.
  private func restoreSessionIfNeeded(into store: WKHTTPCookieStore) async {
    let existing = await store.cookiesSnapshot()
    if existing.contains(where: { $0.domain.hasSuffix(Self.domainSuffix) }) { return }
    guard let cookies = SessionStore.loadCookies(file: Self.sessionFile, domainSuffix: Self.domainSuffix) else { return }
    for c in cookies { await store.setCookie(c) }
  }

  func waitUntilReady() async {
    if isReady { return }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      readyWaiters.append(cont)
    }
  }

  nonisolated func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_800_000_000)   // let the SPA boot
      self.isReady = true
      self.resumeWaiters()
    }
  }

  nonisolated func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
    Task { @MainActor in self.resumeWaiters() }
  }

  nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
    Task { @MainActor in self.resumeWaiters() }
  }

  private func resumeWaiters() {
    let waiters = readyWaiters; readyWaiters.removeAll()
    for w in waiters { w.resume() }
  }

  /// Reload after a long idle stretch to bound WebContent memory growth. Cookies
  /// persist in the data store, so the reloaded page stays logged in.
  func recycleIfIdle(idleThreshold: TimeInterval = 600) {
    guard isReady else { return }
    let now = Date()
    guard now.timeIntervalSince(lastActivity) > idleThreshold,
          now.timeIntervalSince(lastReload) > idleThreshold else { return }
    lastReload = now
    isReady = false
    webView.reload()
  }

  // MARK: - Auth tokens

  /// Scrape the page-embedded XSRF token (`SNlM0e` → sent as `at`) and the build
  /// label (`cfb2h` → sent as `bl`). A missing `at` means the cookies aren't a
  /// logged-in session.
  private struct Tokens { let at: String; let bl: String }

  private func tokens() async throws -> Tokens {
    let js = """
    let at = null, bl = null;
    try { if (window.WIZ_global_data) { at = window.WIZ_global_data.SNlM0e; bl = window.WIZ_global_data.cfb2h; } } catch (e) {}
    if (!at) { const m = document.documentElement.innerHTML.match(/"SNlM0e":"(.*?)"/); if (m) at = m[1]; }
    if (!bl) { const m = document.documentElement.innerHTML.match(/"cfb2h":"(.*?)"/); if (m) bl = m[1]; }
    return JSON.stringify({ at: at || null, bl: bl || null });
    """
    let json = try await runJSON(js, args: [:])
    guard let at = json["at"] as? String, !at.isEmpty else {
      Self.lastDiagnostic = "[tokens] no SNlM0e found — not logged in, or page not the Gemini app"
      throw BridgeError.noAccount
    }
    let bl = (json["bl"] as? String) ?? "boq_assistant-bard-web-server_20240101.00_p0"
    return Tokens(at: at, bl: bl)
  }

  /// Verify the warmed page corresponds to a logged-in account.
  @discardableResult
  func verifyLogin() async throws -> Bool {
    _ = try await tokens()
    await Self.persistSharedSession()   // snapshot the verified session to disk
    return true
  }

  // MARK: - Transcribe

  /// `model` is unused — the Gemini web account serves whatever model it serves
  /// (can't be pinned). `prompt` (e.g. Traditional Chinese steering) is folded
  /// into the transcribe instruction (SPEC §4.5b).
  func transcribe(audioURL: URL, language: String, model: String, prompt: String) async throws -> String {
    guard isReady else { throw BridgeError.notReady }
    lastActivity = Date()
    let data = try Data(contentsOf: audioURL)
    let b64 = data.base64EncodedString()
    let name = audioURL.lastPathComponent
    let mime = audioURL.pathExtension == "wav" ? "audio/wav" : "audio/mp4"

    let fileId = try await uploadFile(b64: b64, mime: mime, filename: name)
    let langHint = language.isEmpty ? "" : " The spoken language is \"\(language)\"."
    let styleHint = prompt.isEmpty ? "" : " Style/preference: \(prompt)"
    let instruction = "Transcribe this audio verbatim.\(langHint) Keep the original language, do not "
      + "translate. Output only the transcript text, no quotes or commentary.\(styleHint)"
    return try await streamGenerate(prompt: instruction, fileId: fileId, filename: name, language: language)
  }

  /// Transcribe AND clean up in a SINGLE StreamGenerate call — Gemini is an LLM,
  /// so it can do both at once, halving latency vs a separate transcribe + cleanup
  /// round-trip. Used when the cleanup pass is enabled (SPEC §4.4b perf note).
  func transcribeAndClean(audioURL: URL, language: String,
                          transcribePrompt: String, cleanupPrompt: String) async throws -> String {
    guard isReady else { throw BridgeError.notReady }
    lastActivity = Date()
    let data = try Data(contentsOf: audioURL)
    let b64 = data.base64EncodedString()
    let name = audioURL.lastPathComponent
    let mime = audioURL.pathExtension == "wav" ? "audio/wav" : "audio/mp4"

    let fileId = try await uploadFile(b64: b64, mime: mime, filename: name)
    let langHint = language.isEmpty ? "" : " The spoken language is \"\(language)\"."
    let styleHint = transcribePrompt.isEmpty ? "" : " 風格/偏好：\(transcribePrompt)"
    let instruction = """
    請先把這段音訊逐字轉錄（保留原語言，不要翻譯），再依下列規則整理，最後只輸出整理後的文字，不要加任何說明、引號或前後綴。\(langHint)\(styleHint)

    \(cleanupPrompt)
    """
    let text = try await streamGenerate(prompt: instruction, fileId: fileId, filename: name, language: language)
    guard !text.isEmpty else { throw BridgeError.badResponse("empty result") }
    return text
  }

  // MARK: - Cleanup

  func cleanup(raw: String, prompt: String, model: String, language: String) async throws -> String {
    guard isReady else { throw BridgeError.notReady }
    lastActivity = Date()
    let message = VoicePrompts.cleanupMessage(prompt: prompt, raw: raw)
    let text = try await streamGenerate(prompt: message, fileId: nil, filename: nil, language: language)
    guard !text.isEmpty else { throw BridgeError.badResponse("empty cleanup result") }
    return text
  }

  // MARK: - File upload

  /// Multipart upload to Google's push endpoint. Returns the opaque file id that
  /// `StreamGenerate` references. Runs in-page so CORS + cookies match the web app.
  private func uploadFile(b64: String, mime: String, filename: String) async throws -> String {
    let js = """
    const bin = atob(audioB64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const blob = new Blob([bytes], { type: mime });
    const fd = new FormData();
    fd.append('file', blob, filename);
    const res = await fetch('https://content-push.googleapis.com/upload/', {
      method: 'POST', body: fd, credentials: 'include',
      headers: { 'Push-ID': 'feeds/mcudyrk2a4khkz' }
    });
    return JSON.stringify({ status: res.status, id: (await res.text()).trim() });
    """
    let json = try await runJSON(js, args: ["audioB64": b64, "mime": mime, "filename": filename])
    let status = (json["status"] as? Int) ?? 0
    guard status == 200, let id = json["id"] as? String, !id.isEmpty else {
      Self.lastDiagnostic = "[upload] HTTP \(status) — audio push failed\n\((json["id"] as? String) ?? "")"
      throw BridgeError.upload(status, (json["id"] as? String) ?? "")
    }
    return id
  }

  // MARK: - StreamGenerate (the fragile part)

  /// Build the `f.req` envelope and POST it to BardFrontendService, then dig the
  /// answer text out of the batchexecute response.
  ///
  /// ⚠️ The `f.req` nesting and the `body[4][0][1][0]` response path are
  /// reverse-engineered from the Gemini web app and change without notice. If this
  /// returns `badResponse`, read `lastRawResponse` and adjust the two marked spots.
  private func streamGenerate(prompt: String, fileId: String?, filename: String?, language: String) async throws -> String {
    let t = try await tokens()

    let js = """
    // ---- f.req construction (ADJUST HERE if Google changes the schema) ----
    // file part, when present: [[[fileId, 1], filename]]
    let fileBlock = null;
    if (fileId) { fileBlock = [[[fileId, 1], filename]]; }
    const inner = [[prompt, 0, null, fileBlock], [language], null];
    const fReq = JSON.stringify([null, JSON.stringify(inner)]);
    // -----------------------------------------------------------------------

    const reqid = Math.floor(Math.random() * 900000) + 100000;
    const url = 'https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate'
      + '?bl=' + encodeURIComponent(bl) + '&_reqid=' + reqid + '&rt=c';
    const body = new URLSearchParams();
    body.append('f.req', fReq);
    body.append('at', at);
    const res = await fetch(url, {
      method: 'POST', credentials: 'include',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: body.toString()
    });
    const raw = await res.text();
    if (!res.ok) return JSON.stringify({ status: res.status, raw: raw.slice(0, 2000) });

    // ---- response parse (ADJUST HERE if the text moves) ----
    let answer = '';
    try {
      for (const line of raw.split('\\n')) {
        const s = line.trim();
        if (!s.startsWith('[')) continue;            // skip ")]}'" and length lines
        let arr; try { arr = JSON.parse(s); } catch (e) { continue; }
        for (const part of arr) {
          if (!Array.isArray(part) || part[0] !== 'wrb.fr' || !part[2]) continue;
          const bodyData = JSON.parse(part[2]);
          const cand = bodyData[4];                  // candidates
          if (cand && cand[0] && cand[0][1] && cand[0][1][0]) {
            answer = cand[0][1][0];                  // first candidate text
          }
        }
      }
    } catch (e) {}
    // --------------------------------------------------------
    return JSON.stringify({ status: res.status, text: answer, raw: answer ? '' : raw.slice(0, 2000) });
    """
    let json = try await runJSON(js, args: [
      "prompt": prompt,
      "fileId": fileId ?? NSNull(),       // bridges to JS null when no attachment
      "filename": filename ?? NSNull(),
      "language": language,
      "at": t.at,
      "bl": t.bl
    ])
    let status = (json["status"] as? Int) ?? 0
    let kind = fileId == nil ? "cleanup" : "transcribe"
    guard status == 200 else {
      lastRawResponse = (json["raw"] as? String) ?? ""
      Self.lastDiagnostic = "[\(kind)] HTTP \(status)\n\(lastRawResponse)"
      throw BridgeError.http(status, lastRawResponse)
    }
    let text = ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      lastRawResponse = (json["raw"] as? String) ?? ""
      Self.lastDiagnostic = "[\(kind)] HTTP 200 but no answer located (envelope drift?)\n\(lastRawResponse)"
      throw BridgeError.badResponse("Could not locate answer in StreamGenerate response. "
        + "Google likely changed the envelope — adjust the parse path in GeminiWebBridge.")
    }
    Self.lastDiagnostic = "[\(kind)] HTTP 200 ✓ parsed \(text.count) chars: \(text.prefix(120))"
    return text
  }

  // MARK: - JS helper

  private func runJSON(_ body: String, args: [String: Any]) async throws -> [String: Any] {
    let result = try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
    guard let s = result as? String, let d = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
      throw BridgeError.badResponse(String(describing: result))
    }
    return obj
  }
}
