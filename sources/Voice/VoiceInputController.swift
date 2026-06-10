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
}

@MainActor
final class VoiceInputController {

  enum Status: Equatable {
    case warming, ready, recording, transcribing, cleaning
    case error(String)
  }

  private(set) var status: Status = .warming
  private var settings: VoiceSettings

  private let recorder = AudioRecorder()
  private let groq = GroqClient()
  private var bridge: ChatGPTBridge?      // created lazily: WKWebView is costly
  private let hotkey = HotkeyManager()
  private var pipeline: Task<Void, Never>?
  private var busy = false
  private var permPoll: Timer?
  private var recTimeout: Timer?

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
    hotkey.updateTrigger(currentTrigger())
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
    // Listen-only CGEventTaps need Input Monitoring on macOS 10.15+ for BOTH
    // trigger modes — flagsChanged (hold_modifier) included (SPEC §8, §15.9).
    if !PermissionsManager.inputMonitoringTrusted {
      PermissionsManager.requestInputMonitoring()
    }
    let ok = hotkey.start(trigger: currentTrigger())
    NSLog("[SquirrelVoice] hotkey installed=%@ axTrusted=%@ inputMonitoring=%@",
          ok ? "YES" : "NO",
          PermissionsManager.accessibilityTrusted ? "YES" : "NO",
          PermissionsManager.inputMonitoringTrusted ? "YES" : "NO")
  }

  /// The tap silently fails until the user grants permissions in System
  /// Settings — poll Accessibility AND Input Monitoring, and (re)install the
  /// moment either flips to granted.
  private func startPermissionPoll() {
    permPoll?.invalidate()
    var lastGranted = PermissionsManager.accessibilityTrusted && PermissionsManager.inputMonitoringTrusted
    permPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let granted = PermissionsManager.accessibilityTrusted && PermissionsManager.inputMonitoringTrusted
        if granted && (!self.hotkey.isInstalled || !lastGranted) {
          _ = self.hotkey.start(trigger: self.currentTrigger())
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
      if settings.backend == .chatgpt { await bridge?.waitUntilReady() }
      status = .transcribing
      let raw = try await provider.transcribe(audioURL: url,
                                              language: settings.transcribeLanguage,
                                              model: settings.transcribeModel,
                                              prompt: settings.transcribePrompt)
      guard !raw.isEmpty else { status = .ready; return }

      var final = raw
      if settings.cleanupEnabled {
        status = .cleaning
        let cleanupModel = settings.backend == .groq ? settings.cleanupModel : settings.cleanupChatGPTModel
        do {
          final = try await provider.cleanup(raw: raw, prompt: VoicePrompts.defaultCleanup,
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

  /// Send text out through the IMK commit channel; fall back per config when
  /// no input session has a focused client.
  private func deliver(_ text: String) {
    if SquirrelInputController.canCommitVoiceText {
      NotificationCenter.default.post(name: .squirrelVoiceCommit, object: text)
      if settings.playSounds { NSSound(named: "Glass")?.play() }
      NSLog("[SquirrelVoice] committed %d chars", text.count)
    } else {
      switch settings.noActiveClient {
      case .clipboard:
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        SquirrelApplicationDelegate.showMessage(
          msgText: NSLocalizedString("Voice text copied — press ⌘V to paste", comment: "Voice"))
        NSLog("[SquirrelVoice] no active client — copied %d chars to clipboard", text.count)
      case .discard:
        NSLog("[SquirrelVoice] no active client — discarded %d chars", text.count)
      }
    }
  }

  private func playErrorFeedback(_ message: String) {
    if settings.playSounds { NSSound.beep() }
    NSLog("[SquirrelVoice] error: %@", message)
  }
}
