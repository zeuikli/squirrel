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
  @Published var cleanupEnabled: Bool
  @Published var maxRecordingSeconds: Int
  @Published var playSounds: Bool
  @Published var cookiesPath: String

  @Published var groqKeyField: String = ""
  @Published var groqKeyStatus: String = ""
  @Published var chatgptLoginStatus: String = ""
  @Published var micAuthorized = PermissionsManager.micAuthorized
  @Published var accessibilityTrusted = PermissionsManager.accessibilityTrusted

  private var permTimer: Timer?

  init() {
    let s = VoiceConfig.load(config: NSApp.squirrelAppDelegate.config)
    enabled = s.enabled
    backend = s.backend
    trigger = s.trigger
    transcribeLanguage = s.transcribeLanguage
    cleanupEnabled = s.cleanupEnabled
    maxRecordingSeconds = s.maxRecordingSeconds
    playSounds = s.playSounds
    cookiesPath = s.cookiesPath
    refreshGroqKeyStatus()
    // Live permission readout: TCC grants flip while System Settings is open.
    permTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshPermissions() }
    }
  }

  deinit {
    permTimer?.invalidate()
  }

  func refreshPermissions() {
    micAuthorized = PermissionsManager.micAuthorized
    accessibilityTrusted = PermissionsManager.accessibilityTrusted
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
    VoiceConfig.set(.trigger, trigger.rawValue)
    VoiceConfig.set(.transcribeLanguage, transcribeLanguage)
    VoiceConfig.set(.cleanupEnabled, cleanupEnabled)
    VoiceConfig.set(.maxRecordingSeconds, maxRecordingSeconds)
    VoiceConfig.set(.playSounds, playSounds)
    VoiceConfig.set(.cookiesPath, cookiesPath)
    VoiceConfig.notifyChanged()
  }

  func saveGroqKey() {
    GroqSecrets.setKeychainKey(groqKeyField)
    groqKeyField = ""
    refreshGroqKeyStatus()
    VoiceConfig.notifyChanged()
  }

  func refreshGroqKeyStatus() {
    if GroqSecrets.keychainKey()?.isEmpty == false {
      groqKeyStatus = NSLocalizedString("Key saved in Keychain", comment: "Voice settings")
    } else if GroqSecrets.hasEnvKey() {
      groqKeyStatus = NSLocalizedString("Key detected from environment / .env", comment: "Voice settings")
    } else {
      groqKeyStatus = NSLocalizedString("No key set", comment: "Voice settings")
    }
  }

  func clearGroqKey() {
    GroqSecrets.setKeychainKey("")
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
}

struct VoiceSettingsView: View {
  @ObservedObject var model: VoiceSettingsModel
  var openLogin: () -> Void

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
        TextField(NSLocalizedString("Language (Whisper code)", comment: "Voice settings"),
                  text: $model.transcribeLanguage)
        Toggle(NSLocalizedString("LLM cleanup pass", comment: "Voice settings"), isOn: $model.cleanupEnabled)
        Stepper(value: $model.maxRecordingSeconds, in: 5...300, step: 5) {
          Text(String(format: NSLocalizedString("Max recording: %d s", comment: "Voice settings"),
                      model.maxRecordingSeconds))
        }
        Toggle(NSLocalizedString("Play sounds", comment: "Voice settings"), isOn: $model.playSounds)
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
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 480)
    .onChange(of: model.enabled) { _ in model.save() }
    .onChange(of: model.backend) { _ in model.save() }
    .onChange(of: model.trigger) { _ in model.save() }
    .onChange(of: model.transcribeLanguage) { _ in model.save() }
    .onChange(of: model.cleanupEnabled) { _ in model.save() }
    .onChange(of: model.maxRecordingSeconds) { _ in model.save() }
    .onChange(of: model.playSounds) { _ in model.save() }
    .onChange(of: model.cookiesPath) { _ in model.save() }
  }
}
