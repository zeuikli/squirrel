//
//  VoiceInputController.swift
//  Squirrel
//
//  Coordinator for voice input (SPEC §5): owns the hotkey, recorder and
//  speech providers, runs the record → transcribe → cleanup pipeline
//  (ported from LizardType AppState.runPipeline), and delivers the final
//  text through the native IMK commit channel via NotificationCenter.
//
//  State machine: idle → recording → transcribing → (cleaning) → commit → idle
//  Any failure → log + sound + back to idle; cleanup failure falls back to
//  the raw transcript so text is never lost.
//

import Foundation
import AppKit

extension Notification.Name {
  /// Posted with the recognized text as `object`; the active
  /// SquirrelInputController commits it to the focused client.
  static let squirrelVoiceCommit = Notification.Name("SquirrelVoiceCommitNotification")
  /// Posted with the new `VoiceInputController.Status` as `object` whenever the
  /// pipeline state changes; the delegate shows a transient menu bar indicator
  /// while voice input is in progress (SPEC §23).
  static let squirrelVoiceStatusChanged = Notification.Name("SquirrelVoiceStatusChangedNotification")
}

@MainActor
final class VoiceInputController {

  enum Status: Equatable {
    case warming, ready, recording, transcribing, cleaning
    case error(String)
  }

  private(set) var status: Status = .warming {
    didSet {
      guard status != oldValue else { return }
      NotificationCenter.default.post(name: .squirrelVoiceStatusChanged, object: status)
    }
  }
  private var settings: VoiceSettings

  private let recorder = AudioRecorder()
  private let groq = GroqClient()
  private var bridge: ChatGPTBridge?            // created lazily: WKWebView is costly
  private var geminiBridge: GeminiWebBridge?    // created lazily: WKWebView is costly
  private let hotkey = HotkeyManager()
  private var pipeline: Task<Void, Never>?
  private var busy = false
  private var permPoll: Timer?
  private var recTimeout: Timer?
  /// The app that was frontmost when the hotkey was pressed — delivery targets
  /// this, not whoever is frontmost seconds later when recognition finishes.
  private var captureTargetApp: NSRunningApplication?

  init(settings: VoiceSettings) {
    self.settings = settings
  }

  // MARK: - Lifecycle

  func start() {
    wireHotkey()
    Task { await warmBackend() }
    startPermissionPoll()
    if !PermissionsManager.accessibilityTrusted {
      // Ad-hoc builds get a fresh code signature on every reinstall, which
      // invalidates the previous TCC grant — surface it instead of failing
      // silently (SPEC §15.9).
      SquirrelApplicationDelegate.showMessage(
        msgText: NSLocalizedString("Voice input needs Accessibility — re-grant Squirrel in System Settings", comment: "Voice"))
      PermissionsManager.promptAccessibility()
    }
    if PermissionsManager.micUndetermined {
      // The mic prompt can only be raised by the app itself (no '+' button in
      // System Settings) — ask at startup instead of on the first hotkey press.
      Task { _ = await PermissionsManager.requestMic() }
    }
    NSLog("[SquirrelVoice] started (backend=%@ trigger=%@)",
          settings.backend.rawValue, settings.trigger.rawValue)
  }

  func stop() {
    permPoll?.invalidate()
    permPoll = nil
    recTimeout?.invalidate()
    recTimeout = nil
    hotkey.stop()
    pipeline?.cancel()
    recorder.cancel()
    NSLog("[SquirrelVoice] stopped")
  }

  /// Apply new settings in place (idempotent; called on deploy / UI change).
  func reload(settings: VoiceSettings) {
    self.settings = settings
    if currentEngine() == .cgtap, !PermissionsManager.inputMonitoringTrusted {
      PermissionsManager.requestInputMonitoring()
    }
    hotkey.updateTrigger(currentTrigger(), engine: currentEngine())
    Task { await warmBackend() }
    NSLog("[SquirrelVoice] settings reloaded (backend=%@)", settings.backend.rawValue)
  }

  // MARK: - Backend

  private var activeProvider: SpeechProvider {
    switch settings.backend {
    case .groq:
      return groq
    case .chatgpt:
      if bridge == nil { bridge = ChatGPTBridge() }
      return bridge!
    case .geminiWeb:
      if geminiBridge == nil { geminiBridge = GeminiWebBridge() }
      return geminiBridge!
    }
  }

  /// Web-session backends warm a WKWebView; await it before transcribing so the
  /// first hotkey press after launch doesn't race the page load.
  private func awaitWebReadyIfNeeded() async {
    switch settings.backend {
    case .chatgpt:   await bridge?.waitUntilReady()
    case .geminiWeb: await geminiBridge?.waitUntilReady()
    default:         break
    }
  }

  /// Transcribe model for the active backend (Whisper for Groq); the web
  /// bridges (ChatGPT, Gemini) ignore it and pick their own.
  private var activeTranscribeModel: String { settings.transcribeModel }

  /// Cleanup LLM model for the active backend; web bridges ignore it.
  private var activeCleanupModel: String {
    switch settings.backend {
    case .groq:      return settings.cleanupModel
    case .chatgpt:   return settings.cleanupChatGPTModel
    case .geminiWeb: return settings.cleanupModel   // ignored by the web bridge
    }
  }

  private func warmBackend() async {
    status = .warming
    switch settings.backend {
    case .groq:
      do {
        try await groq.validate()
        status = .ready
        NSLog("[SquirrelVoice] Groq provider ready")
      } catch {
        status = .error(error.localizedDescription)
        NSLog("[SquirrelVoice] Groq warm failed: %@", error.localizedDescription)
      }
    case .chatgpt:
      if bridge == nil { bridge = ChatGPTBridge() }
      do {
        try await bridge!.start(cookiesPath: settings.cookiesPath)
        await bridge!.waitUntilReady()
        _ = try await bridge!.accessToken(forceRefresh: true)   // verify login
        status = .ready
        NSLog("[SquirrelVoice] ChatGPT bridge ready — logged in")
      } catch {
        status = .error(error.localizedDescription)
        NSLog("[SquirrelVoice] ChatGPT warm failed: %@", error.localizedDescription)
      }
    case .geminiWeb:
      if geminiBridge == nil { geminiBridge = GeminiWebBridge() }
      do {
        try await geminiBridge!.start(cookiesPath: settings.geminiCookiesPath)
        await geminiBridge!.waitUntilReady()
        _ = try await geminiBridge!.verifyLogin()   // verify session
        status = .ready
        NSLog("[SquirrelVoice] Gemini web bridge ready — logged in")
      } catch {
        status = .error(error.localizedDescription)
        NSLog("[SquirrelVoice] Gemini web warm failed: %@", error.localizedDescription)
      }
    }
  }

  // MARK: - Hotkey

  private func currentTrigger() -> HotkeyManager.Trigger {
    if settings.hotkeyMode == "custom_combo" {
      return .keyCombo(keyCode: Int64(settings.customKeyCode),
                       mods: Self.cgFlags(settings.customModifiers))
    }
    return .modifier(settings.trigger)
  }

  private func currentEngine() -> HotkeyManager.Engine {
    HotkeyManager.Engine(rawValue: settings.hotkeyEngine) ?? .nsevent
  }

  /// True when every permission the selected engine needs is granted.
  private func hotkeyPermissionsGranted() -> Bool {
    let ax = PermissionsManager.accessibilityTrusted
    return currentEngine() == .cgtap ? ax && PermissionsManager.inputMonitoringTrusted : ax
  }

  static func cgFlags(_ raw: UInt) -> CGEventFlags {
    let m = NSEvent.ModifierFlags(rawValue: raw)
    var f: CGEventFlags = []
    if m.contains(.command) { f.insert(.maskCommand) }
    if m.contains(.option)  { f.insert(.maskAlternate) }
    if m.contains(.control) { f.insert(.maskControl) }
    if m.contains(.shift)   { f.insert(.maskShift) }
    return f
  }

  private func wireHotkey() {
    hotkey.onStart = { [weak self] in self?.beginRecording() }
    hotkey.onStop = { [weak self] in self?.finishRecording() }
    // The cgtap engine additionally needs Input Monitoring (SPEC §15.9);
    // nsevent only needs Accessibility.
    if currentEngine() == .cgtap, !PermissionsManager.inputMonitoringTrusted {
      PermissionsManager.requestInputMonitoring()
    }
    let ok = hotkey.start(trigger: currentTrigger(), engine: currentEngine())
    NSLog("[SquirrelVoice] hotkey installed=%@ axTrusted=%@",
          ok ? "YES" : "NO",
          PermissionsManager.accessibilityTrusted ? "YES" : "NO")
  }

  /// Monitors/taps deliver nothing until their permissions are granted —
  /// poll and reinstall the moment they flip to granted.
  private func startPermissionPoll() {
    permPoll?.invalidate()
    var lastGranted = hotkeyPermissionsGranted()
    permPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let granted = self.hotkeyPermissionsGranted()
        if granted && (!self.hotkey.isInstalled || !lastGranted) {
          _ = self.hotkey.start(trigger: self.currentTrigger(), engine: self.currentEngine())
          NSLog("[SquirrelVoice] hotkey (re)installed after permission grant")
        }
        lastGranted = granted
      }
    }
  }

  // MARK: - Recording pipeline

  private func beginRecording() {
    guard !busy, !recorder.isRecording else { return }
    if case .warming = status { playErrorFeedback("voice backend still warming"); return }
    // Pin the delivery target NOW (hotkey press), while the user's app is still
    // frontmost — not at delivery time, which is seconds later after recognition.
    let front = NSWorkspace.shared.frontmostApplication
    if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
      captureTargetApp = front   // ignore the case where our own Settings window is front
    }
    Task {
      guard await PermissionsManager.requestMic() else {
        status = .error("Microphone permission needed")
        playErrorFeedback("microphone permission needed")
        return
      }
      do {
        try recorder.start()
        status = .recording
        if settings.playSounds { NSSound(named: "Tink")?.play() }
        // safety: auto-stop at the configured max duration
        recTimeout?.invalidate()
        recTimeout = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.maxRecordingSeconds),
                                          repeats: false) { [weak self] _ in
          Task { @MainActor in self?.finishRecording() }
        }
      } catch {
        status = .error(error.localizedDescription)
        playErrorFeedback(error.localizedDescription)
      }
    }
  }

  private func finishRecording() {
    recTimeout?.invalidate()
    recTimeout = nil
    guard recorder.isRecording else { return }
    if settings.playSounds { NSSound(named: "Pop")?.play() }
    guard let (url, durationMs) = recorder.stop() else { status = .ready; return }
    guard durationMs >= 400 else {          // ignore accidental taps / silence
      recorder.cleanup(url)
      status = .ready
      return
    }
    pipeline?.cancel()
    pipeline = Task { await runPipeline(url: url) }
  }

  private func runPipeline(url: URL) async {
    busy = true
    defer {
      busy = false
      recorder.cleanup(url)
    }
    do {
      let provider = activeProvider
      await awaitWebReadyIfNeeded()
      status = .transcribing

      // Fast path: Gemini Web is an LLM, so transcribe + cleanup run in ONE
      // StreamGenerate call (halves network latency vs two round-trips).
      if settings.cleanupEnabled, let gemini = provider as? GeminiWebBridge {
        let final = try await gemini.transcribeAndClean(audioURL: url,
                                                        language: settings.transcribeLanguage,
                                                        transcribePrompt: settings.transcribePrompt,
                                                        cleanupPrompt: settings.cleanupPrompt)
        guard !final.isEmpty else { status = .ready; return }
        deliver(final)
        status = .ready
        return
      }

      let raw = try await provider.transcribe(audioURL: url,
                                              language: settings.transcribeLanguage,
                                              model: activeTranscribeModel,
                                              prompt: settings.transcribePrompt)
      guard !raw.isEmpty else { status = .ready; return }

      var final = raw
      if settings.cleanupEnabled {
        status = .cleaning
        let cleanupModel = activeCleanupModel
        do {
          final = try await provider.cleanup(raw: raw, prompt: settings.cleanupPrompt,
                                             model: cleanupModel, language: settings.cleanupLanguage)
        } catch {
          // Cleanup failed — fall back to the raw transcript so text is never lost.
          final = raw
          NSLog("[SquirrelVoice] cleanup skipped: %@", error.localizedDescription)
        }
      }
      deliver(final)
      status = .ready
    } catch {
      status = .error(error.localizedDescription)
      playErrorFeedback(error.localizedDescription)
    }
  }

  /// Process-wide diagnostic of the last delivery (which path took the text).
  /// Surfaced in the Settings diagnostics area next to the web RPC log so a
  /// failed "nothing was typed" can be told apart from a backend failure.
  @MainActor static var lastCommitDiagnostic = ""

  /// Bundle-id substrings of Chromium/Electron apps that silently drop an async
  /// IMK `insertText` AND synthesized Unicode typing (both confirmed not to land
  /// in VSCode). Voice text for these is delivered via clipboard + ⌘V paste, the
  /// only method that works there. Every other app keeps the native IMK
  /// auto-commit (SPEC §4.1) — confirmed working in Telegram / ChatGPT / native.
  static let pasteDeliveryApps = [
    "com.microsoft.vscode", "com.vscodium", "com.visualstudio.code",   // VS Code / VSCodium
    "com.google.chrome", "com.microsoft.edgmac", "com.microsoft.edgemac",
    "com.brave.browser", "org.chromium", "company.thebrowser.browser", // Chromium browsers / Arc
    "com.tinyspeck.slackmacgap", "com.hnc.discord", "com.electron"
  ]

  static func needsPasteDelivery(_ bundleID: String) -> Bool {
    let id = bundleID.lowercased()
    return pasteDeliveryApps.contains { !$0.isEmpty && id.contains($0) }
  }

  /// Send text out. The native IMK `insertText` (SPEC §4.1) gives clean auto-commit
  /// in most apps, so it's the default. But voice text arrives out-of-band (seconds
  /// after the hotkey), and Chromium/Electron apps (VSCode, …) silently drop both
  /// an async insertText and synthesized Unicode typing — for those, clipboard + ⌘V
  /// paste is the only thing that lands. Choice is per frontmost app; all auto-type.
  private func deliver(_ text: String) {
    if settings.playSounds { NSSound(named: "Glass")?.play() }
    // Decide by the app pinned at hotkey press, and re-front it so focus drift
    // during recognition can't redirect the text to another window.
    let target = captureTargetApp ?? NSWorkspace.shared.frontmostApplication
    let bundleID = target?.bundleIdentifier ?? ""
    let frontNow = NSWorkspace.shared.frontmostApplication
    if let target = target, target != frontNow {
      target.activate(options: [])   // bring the capture app back to front
    }
    if Self.needsPasteDelivery(bundleID) {
      Self.lastCommitDiagnostic = "[commit] \(bundleID) → clipboard + ⌘V paste (\(text.count) chars)"
      pasteViaClipboard(text)
    } else if SquirrelInputController.canCommitVoiceText {
      NotificationCenter.default.post(name: .squirrelVoiceCommit, object: text)
      Self.lastCommitDiagnostic = "[commit] \(bundleID) → IMK insertText (\(text.count) chars)"
      NSLog("[SquirrelVoice] committed %d chars via IMK to %@", text.count, bundleID)
    } else {
      // No active IMK client (some apps activate their IME only on first compose).
      Self.lastCommitDiagnostic = "[commit] \(bundleID) → no IMK client, clipboard + ⌘V paste (\(text.count) chars)"
      pasteViaClipboard(text)
    }
  }

  /// Put `text` on the pasteboard and synthesize ⌘V into the focused app.
  /// Matches LizardType's proven TextInserter: HID-level event, posted after a
  /// short delay so the push-to-talk key-release events have drained first.
  ///
  /// IMPORTANT: we do NOT restore the previous clipboard. Electron apps (VSCode)
  /// read the pasteboard *asynchronously* after the synthetic ⌘V — often >1s
  /// later — so an early restore makes them paste the PREVIOUS clipboard content
  /// (confirmed: "keeps last text"). The recognized text stays on the clipboard.
  private func pasteViaClipboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)

    guard PermissionsManager.accessibilityTrusted else {
      // Can't synthesize keys without Accessibility — leave text on the clipboard.
      Self.lastCommitDiagnostic = "[commit] clipboard set, but Accessibility OFF → can't auto-paste; press ⌘V (\(text.count) chars)"
      SquirrelApplicationDelegate.showMessage(
        msgText: NSLocalizedString("Voice text copied — press ⌘V to paste", comment: "Voice"))
      return
    }

    NSLog("[SquirrelVoice] delivered %d chars via clipboard paste", text.count)

    // Synthesize ⌘V at HID level (most reliable; delivered to the frontmost app).
    // The 0.15s delay lets the push-to-talk modifier key-up settle AND the target
    // app's re-activation (in deliver) finish, so the ⌘V isn't merged with a stale
    // Option flag and lands in the right window.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      let src = CGEventSource(stateID: .hidSystemState)
      let vKey = CGKeyCode(9)   // 'v'
      let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
      down?.flags = .maskCommand
      let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
      up?.flags = .maskCommand
      down?.post(tap: .cghidEventTap)
      up?.post(tap: .cghidEventTap)
    }
  }

  private func playErrorFeedback(_ message: String) {
    if settings.playSounds { NSSound.beep() }
    NSLog("[SquirrelVoice] error: %@", message)
  }
}
