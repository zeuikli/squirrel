//
//  VoiceSettingsView.swift
//  Squirrel
//
//  SwiftUI settings form for voice input (SPEC §14). Adapted from LizardType
//  SettingsView, bound to VoiceConfig (UserDefaults layer) instead of
//  AppSettings. Edits persist immediately and notify the running
//  VoiceInputController via VoiceConfig.notifyChanged().
//

import SwiftUI

/// Observable bridge between the form and the UserDefaults layer.
@MainActor
final class VoiceSettingsModel: ObservableObject {
  @Published var enabled: Bool
  @Published var backend: VoiceBackend
  @Published var trigger: VoiceTriggerKind
  @Published var transcribeLanguage: String
  @Published var transcribePromptText: String
  @Published var cleanupPromptText: String
  @Published var cleanupEnabled: Bool
  @Published var maxRecordingSeconds: Int
  @Published var playSounds: Bool
  @Published var cookiesPath: String
  @Published var geminiCookiesPath: String

  @Published var groqKeyField: String = ""
  @Published var groqKeyStatus: String = ""
  @Published var chatgptLoginStatus: String = ""
  @Published var geminiLoginStatus: String = ""
  @Published var geminiWebDiagnostic: String = ""   // last StreamGenerate raw/result
  @Published var hotkeyEngine: String
  @Published var micAuthorized = PermissionsManager.micAuthorized
  @Published var accessibilityTrusted = PermissionsManager.accessibilityTrusted
  @Published var inputMonitoringTrusted = PermissionsManager.inputMonitoringTrusted

  private var permTimer: Timer?
  private var lastLanguage: String = "zh"
  private var promptSaveTask: Task<Void, Never>?

  init() {
    let s = VoiceConfig.load(config: NSApp.squirrelAppDelegate.config)
    enabled = s.enabled
    backend = s.backend
    hotkeyEngine = s.hotkeyEngine
    trigger = s.trigger
    transcribeLanguage = s.transcribeLanguage
    transcribePromptText = s.transcribePrompt
    cleanupPromptText = s.cleanupPrompt
    cleanupEnabled = s.cleanupEnabled
    maxRecordingSeconds = s.maxRecordingSeconds
    playSounds = s.playSounds
    cookiesPath = s.cookiesPath
    geminiCookiesPath = s.geminiCookiesPath
    lastLanguage = s.transcribeLanguage
    refreshGroqKeyStatus()
    // Live permission readout: TCC grants flip while System Settings is open.
    permTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshPermissions() }
    }
  }

  deinit {
    permTimer?.invalidate()
    promptSaveTask?.cancel()
  }

  func refreshPermissions() {
    micAuthorized = PermissionsManager.micAuthorized
    accessibilityTrusted = PermissionsManager.accessibilityTrusted
    inputMonitoringTrusted = PermissionsManager.inputMonitoringTrusted
    // Live-update diagnostics while the window is open: the web RPC result plus
    // which delivery path the recognized text took (IMK vs clipboard paste).
    geminiWebDiagnostic = [GeminiWebBridge.lastDiagnostic, VoiceInputController.lastCommitDiagnostic]
      .filter { !$0.isEmpty }
      .joined(separator: "\n———\n")
  }

  /// Trigger the system Input Monitoring prompt; if it doesn't appear
  /// (already denied / stale record), open System Settings — remove (−) and
  /// re-add (+) the entry there if the toggle keeps switching itself off.
  func requestInputMonitoring() {
    if !PermissionsManager.requestInputMonitoring() {
      PermissionsManager.openInputMonitoringSettings()
    }
    refreshPermissions()
  }

  /// Trigger the system mic prompt while it is still available
  /// (.notDetermined); after a denial only System Settings can re-enable.
  func requestMicAccess() {
    if PermissionsManager.micUndetermined {
      Task { @MainActor [weak self] in
        _ = await PermissionsManager.requestMic()
        self?.refreshPermissions()
      }
    } else {
      PermissionsManager.openMicSettings()
    }
  }

  func save() {
    VoiceConfig.set(.enabled, enabled)
    VoiceConfig.set(.backend, backend.rawValue)
    VoiceConfig.set(.hotkeyEngine, hotkeyEngine)
    VoiceConfig.set(.trigger, trigger.rawValue)
    VoiceConfig.set(.transcribeLanguage, transcribeLanguage)
    VoiceConfig.set(.cleanupEnabled, cleanupEnabled)
    VoiceConfig.set(.maxRecordingSeconds, maxRecordingSeconds)
    VoiceConfig.set(.playSounds, playSounds)
    VoiceConfig.set(.cookiesPath, cookiesPath)
    VoiceConfig.set(.geminiCookiesPath, geminiCookiesPath)
    persistPrompts()
    VoiceConfig.notifyChanged()
  }

  // MARK: - Prompts (SPEC §20)

  /// Store a prompt override only when it differs from the language default,
  /// so un-customized prompts follow the language selection.
  private func persistPrompts() {
    let tDefault = VoicePrompts.transcribeDefault(language: transcribeLanguage)
    let cDefault = VoicePrompts.cleanupDefault(language: transcribeLanguage)
    VoiceConfig.set(.transcribePrompt, transcribePromptText == tDefault ? nil : transcribePromptText)
    VoiceConfig.set(.cleanupPrompt, cleanupPromptText == cDefault ? nil : cleanupPromptText)
  }

  /// Debounced save for the prompt editors — a per-keystroke notify would
  /// re-warm the backend (and reload the ChatGPT WebView) on every key.
  func savePromptsDebounced() {
    promptSaveTask?.cancel()
    promptSaveTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 800_000_000)
      guard !Task.isCancelled, let self else { return }
      self.persistPrompts()
      VoiceConfig.notifyChanged()
    }
  }

  /// Swap un-customized prompts to the new language's defaults.
  func languageChanged() {
    if transcribePromptText == VoicePrompts.transcribeDefault(language: lastLanguage) {
      transcribePromptText = VoicePrompts.transcribeDefault(language: transcribeLanguage)
    }
    if cleanupPromptText == VoicePrompts.cleanupDefault(language: lastLanguage) {
      cleanupPromptText = VoicePrompts.cleanupDefault(language: transcribeLanguage)
    }
    lastLanguage = transcribeLanguage
    save()
  }

  func resetTranscribePrompt() {
    transcribePromptText = VoicePrompts.transcribeDefault(language: transcribeLanguage)
    save()
  }

  func resetCleanupPrompt() {
    cleanupPromptText = VoicePrompts.cleanupDefault(language: transcribeLanguage)
    save()
  }

  func saveGroqKey() {
    GroqSecrets.setStoredKey(groqKeyField)
    groqKeyField = ""
    refreshGroqKeyStatus()
    VoiceConfig.notifyChanged()
  }

  func refreshGroqKeyStatus() {
    if GroqSecrets.storedKey()?.isEmpty == false {
      groqKeyStatus = NSLocalizedString("Key saved", comment: "Voice settings")
    } else if GroqSecrets.hasEnvKey() {
      groqKeyStatus = NSLocalizedString("Key detected from environment / .env", comment: "Voice settings")
    } else {
      groqKeyStatus = NSLocalizedString("No key set", comment: "Voice settings")
    }
  }

  func clearGroqKey() {
    GroqSecrets.setStoredKey("")
    refreshGroqKeyStatus()
  }

  /// Probe the persistent ChatGPT session and report the login state.
  func refreshChatGPTStatus() {
    chatgptLoginStatus = NSLocalizedString("Checking…", comment: "Voice settings")
    Task { @MainActor in
      let bridge = ChatGPTBridge()
      do {
        try await bridge.start(cookiesPath: cookiesPath)
        await bridge.waitUntilReady()
        _ = try await bridge.accessToken(forceRefresh: true)
        chatgptLoginStatus = NSLocalizedString("Logged in ✓", comment: "Voice settings")
      } catch {
        chatgptLoginStatus = NSLocalizedString("Not logged in", comment: "Voice settings")
      }
    }
  }

  // MARK: - Gemini (web session)

  /// Probe the persistent Gemini web session and report the login state.
  func refreshGeminiStatus() {
    geminiLoginStatus = NSLocalizedString("Checking…", comment: "Voice settings")
    Task { @MainActor in
      let bridge = GeminiWebBridge()
      do {
        try await bridge.start(cookiesPath: geminiCookiesPath)
        await bridge.waitUntilReady()
        _ = try await bridge.verifyLogin()
        geminiLoginStatus = NSLocalizedString("Logged in ✓", comment: "Voice settings")
      } catch {
        geminiLoginStatus = NSLocalizedString("Not logged in", comment: "Voice settings")
      }
      refreshGeminiDiagnostic()
    }
  }

  func refreshGeminiDiagnostic() {
    geminiWebDiagnostic = GeminiWebBridge.lastDiagnostic
  }
}

struct VoiceSettingsView: View {
  @ObservedObject var model: VoiceSettingsModel
  var openLogin: () -> Void
  var openGeminiLogin: () -> Void
  /// Diagnostics are hidden by default; users expand only when troubleshooting.
  @State private var showDiagnostics = false

  var body: some View {
    Form {
      Section(NSLocalizedString("Permissions", comment: "Voice settings")) {
        LabeledContent(NSLocalizedString("Microphone", comment: "Voice settings")) {
          Text(model.micAuthorized ? "✓" : NSLocalizedString("✗ not granted", comment: "Voice settings"))
            .foregroundColor(model.micAuthorized ? .green : .red)
        }
        LabeledContent(NSLocalizedString("Accessibility (push-to-talk key)", comment: "Voice settings")) {
          Text(model.accessibilityTrusted ? "✓" : NSLocalizedString("✗ not granted", comment: "Voice settings"))
            .foregroundColor(model.accessibilityTrusted ? .green : .red)
        }
        if model.hotkeyEngine == "cgtap" {
          LabeledContent(NSLocalizedString("Input Monitoring (CGEventTap engine)", comment: "Voice settings")) {
            Text(model.inputMonitoringTrusted ? "✓" : NSLocalizedString("✗ not granted", comment: "Voice settings"))
              .foregroundColor(model.inputMonitoringTrusted ? .green : .red)
          }
          if !model.inputMonitoringTrusted {
            HStack {
              Text(NSLocalizedString("If the toggle keeps switching itself off, remove (−) and re-add (+) Squirrel in the list.", comment: "Voice settings"))
                .font(.footnote)
                .foregroundColor(.orange)
              Spacer()
              Button(NSLocalizedString("Grant input monitoring…", comment: "Voice settings")) {
                model.requestInputMonitoring()
              }
            }
          }
        }
        if !model.micAuthorized {
          HStack {
            Text(NSLocalizedString("Microphone access is required for recording.", comment: "Voice settings"))
              .font(.footnote)
              .foregroundColor(.orange)
            Spacer()
            Button(NSLocalizedString("Grant microphone…", comment: "Voice settings")) {
              model.requestMicAccess()
            }
          }
        }
        if !model.accessibilityTrusted {
          HStack {
            Text(NSLocalizedString("Accessibility is required for the push-to-talk key.", comment: "Voice settings"))
              .font(.footnote)
              .foregroundColor(.orange)
            Spacer()
            Button(NSLocalizedString("Open System Settings", comment: "Voice settings")) {
              PermissionsManager.openAccessibilitySettings()
            }
          }
        }
      }

      Section {
        Toggle(NSLocalizedString("Enable voice input", comment: "Voice settings"), isOn: $model.enabled)
        Picker(NSLocalizedString("Backend", comment: "Voice settings"), selection: $model.backend) {
          ForEach(VoiceBackend.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker(NSLocalizedString("Push-to-talk key", comment: "Voice settings"), selection: $model.trigger) {
          ForEach(VoiceTriggerKind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker(NSLocalizedString("Hotkey engine", comment: "Voice settings"), selection: $model.hotkeyEngine) {
          Text(NSLocalizedString("NSEvent (Accessibility only)", comment: "Voice settings")).tag("nsevent")
          Text(NSLocalizedString("CGEventTap (+ Input Monitoring)", comment: "Voice settings")).tag("cgtap")
        }
        Picker(NSLocalizedString("Language", comment: "Voice settings"), selection: $model.transcribeLanguage) {
          ForEach(VoiceLanguages.supported, id: \.code) { Text($0.label).tag($0.code) }
          if !VoiceLanguages.supported.contains(where: { $0.code == model.transcribeLanguage }) {
            // Keep a non-listed Whisper code set via yaml selectable.
            Text("Custom (\(model.transcribeLanguage))").tag(model.transcribeLanguage)
          }
        }
        Toggle(NSLocalizedString("LLM cleanup pass", comment: "Voice settings"), isOn: $model.cleanupEnabled)
        Stepper(value: $model.maxRecordingSeconds, in: 5...300, step: 5) {
          Text(String(format: NSLocalizedString("Max recording: %d s", comment: "Voice settings"),
                      model.maxRecordingSeconds))
        }
        Toggle(NSLocalizedString("Play sounds", comment: "Voice settings"), isOn: $model.playSounds)
      }

      Section(NSLocalizedString("Prompts", comment: "Voice settings")) {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(NSLocalizedString("Transcribe prompt (Whisper initial prompt)", comment: "Voice settings"))
            Spacer()
            Button(NSLocalizedString("Reset to default", comment: "Voice settings")) {
              model.resetTranscribePrompt()
            }
          }
          TextEditor(text: $model.transcribePromptText)
            .font(.system(.footnote))
            .frame(minHeight: 48, maxHeight: 80)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
          if model.backend == .chatgpt {
            Text(NSLocalizedString("Not supported by the ChatGPT Web backend — Groq only.", comment: "Voice settings"))
              .font(.footnote)
              .foregroundColor(.orange)
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(NSLocalizedString("Cleanup system prompt (LLM pass)", comment: "Voice settings"))
            Spacer()
            Button(NSLocalizedString("Reset to default", comment: "Voice settings")) {
              model.resetCleanupPrompt()
            }
          }
          TextEditor(text: $model.cleanupPromptText)
            .font(.system(.footnote))
            .frame(minHeight: 100, maxHeight: 180)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
          Text(NSLocalizedString("Un-edited prompts follow the language selection; edited prompts apply to all languages until reset.", comment: "Voice settings"))
            .font(.footnote)
            .foregroundColor(.secondary)
        }
      }

      if model.backend == .groq {
        Section(NSLocalizedString("Groq API key", comment: "Voice settings")) {
          LabeledContent(NSLocalizedString("Status", comment: "Voice settings")) {
            Text(model.groqKeyStatus.isEmpty
                 ? NSLocalizedString("Not checked —", comment: "Voice settings")
                 : model.groqKeyStatus)
              .foregroundColor(.secondary)
          }
          SecureField(NSLocalizedString("API key", comment: "Voice settings"), text: $model.groqKeyField,
                      prompt: Text(NSLocalizedString("Paste your Groq API key", comment: "Voice settings")))
          HStack {
            Button(NSLocalizedString("Save key", comment: "Voice settings")) { model.saveGroqKey() }
              .disabled(model.groqKeyField.isEmpty)
            Button(NSLocalizedString("Clear", comment: "Voice settings")) { model.clearGroqKey() }
          }
        }
      }

      if model.backend == .chatgpt {
        Section(NSLocalizedString("ChatGPT session", comment: "Voice settings")) {
          LabeledContent(NSLocalizedString("Status", comment: "Voice settings")) {
            Text(model.chatgptLoginStatus.isEmpty
                 ? NSLocalizedString("Not checked —", comment: "Voice settings")
                 : model.chatgptLoginStatus)
              .foregroundColor(.secondary)
          }
          HStack {
            Button(NSLocalizedString("Sign in to ChatGPT…", comment: "Voice settings")) { openLogin() }
            Button(NSLocalizedString("Check status", comment: "Voice settings")) { model.refreshChatGPTStatus() }
          }
          TextField(NSLocalizedString("cookies.json path", comment: "Voice settings"),
                    text: $model.cookiesPath,
                    prompt: Text(NSLocalizedString("Optional, legacy — UI sign-in is preferred", comment: "Voice settings")))
        }
      }

      if model.backend == .geminiWeb {
        Section(NSLocalizedString("Gemini session", comment: "Voice settings")) {
          LabeledContent(NSLocalizedString("Status", comment: "Voice settings")) {
            Text(model.geminiLoginStatus.isEmpty
                 ? NSLocalizedString("Not checked —", comment: "Voice settings")
                 : model.geminiLoginStatus)
              .foregroundColor(.secondary)
          }
          HStack {
            Button(NSLocalizedString("Sign in to Gemini…", comment: "Voice settings")) { openGeminiLogin() }
            Button(NSLocalizedString("Check status", comment: "Voice settings")) { model.refreshGeminiStatus() }
          }
          TextField(NSLocalizedString("google.com cookies.json path", comment: "Voice settings"),
                    text: $model.geminiCookiesPath,
                    prompt: Text(NSLocalizedString("Optional, legacy — UI sign-in is preferred", comment: "Voice settings")))
          Text(NSLocalizedString("Experimental — drives gemini.google.com via a reverse-engineered RPC that can break without notice. Prefer the Gemini API backend.", comment: "Voice settings"))
            .font(.footnote)
            .foregroundColor(.orange)
          // Diagnostics hidden by default — expand only when troubleshooting.
          DisclosureGroup(isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Spacer()
                Button(NSLocalizedString("Refresh", comment: "Voice settings")) { model.refreshGeminiDiagnostic() }
                Button(NSLocalizedString("Copy", comment: "Voice settings")) {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(model.geminiWebDiagnostic, forType: .string)
                }.disabled(model.geminiWebDiagnostic.isEmpty)
              }
              ScrollView {
                Text(model.geminiWebDiagnostic.isEmpty
                     ? NSLocalizedString("No StreamGenerate call yet — sign in, then try a voice capture.", comment: "Voice settings")
                     : model.geminiWebDiagnostic)
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxHeight: 160)
              .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            .padding(.top, 4)
          } label: {
            Text(NSLocalizedString("Diagnostics (advanced)", comment: "Voice settings"))
              .font(.footnote)
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 480)
    .onChange(of: model.enabled) { _ in model.save() }
    .onChange(of: model.backend) { _ in model.save() }
    .onChange(of: model.hotkeyEngine) { _ in model.save() }
    .onChange(of: model.trigger) { _ in model.save() }
    .onChange(of: model.transcribeLanguage) { _ in model.languageChanged() }
    .onChange(of: model.transcribePromptText) { _ in model.savePromptsDebounced() }
    .onChange(of: model.cleanupPromptText) { _ in model.savePromptsDebounced() }
    .onChange(of: model.cleanupEnabled) { _ in model.save() }
    .onChange(of: model.maxRecordingSeconds) { _ in model.save() }
    .onChange(of: model.playSounds) { _ in model.save() }
    .onChange(of: model.cookiesPath) { _ in model.save() }
    .onChange(of: model.geminiCookiesPath) { _ in model.save() }
  }
}
