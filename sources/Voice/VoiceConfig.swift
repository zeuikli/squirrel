//
//  VoiceConfig.swift
//  Squirrel
//
//  Voice input settings. Three layers (first hit wins):
//  UserDefaults (set from the Settings UI) > squirrel.yaml `voice_input/*`
//  (deploy-time defaults) > hard-coded defaults. See SPEC §14.3.
//

import AppKit

/// Speech backend.
enum VoiceBackend: String, CaseIterable {
  case groq
  case chatgpt

  var label: String {
    switch self {
    case .groq:    return "Groq API (key)"
    case .chatgpt: return "ChatGPT Web (session)"
    }
  }
}

/// Hold-to-talk single-modifier trigger.
enum VoiceTriggerKind: String, CaseIterable {
  case rightOption = "right_option"
  case rightCommand = "right_command"
  case rightControl = "right_control"
  case fn

  var label: String {
    switch self {
    case .rightOption:  return "Right Option ⌥ (hold)"
    case .rightCommand: return "Right Command ⌘ (hold)"
    case .rightControl: return "Right Control ⌃ (hold)"
    case .fn:           return "Fn / 🌐 (hold)"
    }
  }
}

/// What to do with recognized text when no text field has focus.
enum VoiceNoClientFallback: String {
  case clipboard
  case discard
}

/// Whisper languages offered in the UI (SPEC §19.1). Other ISO-639-1 codes
/// set via yaml still work — the picker shows them as a custom entry.
enum VoiceLanguages {
  static let supported: [(code: String, label: String)] = [
    ("zh", "繁體中文"),
    ("en", "English"),
    ("ja", "日本語"),
    ("ko", "한국어"),
    ("de", "Deutsch"),
    ("fr", "Français"),
    ("it", "Italiano"),
    ("es", "Español"),
    ("pt", "Português")
  ]
}

/// Immutable snapshot consumed by `VoiceInputController`.
struct VoiceSettings {
  var enabled: Bool = true
  var backend: VoiceBackend = .groq
  var cookiesPath: String = ""
  var hotkeyMode: String = "hold_modifier"   // hold_modifier | custom_combo
  var hotkeyEngine: String = "nsevent"       // nsevent (AX only) | cgtap (AX + Input Monitoring)
  var trigger: VoiceTriggerKind = .rightOption
  var customKeyCode: Int = 49                // Space
  var customModifiers: UInt = NSEvent.ModifierFlags([.control, .option]).rawValue
  var transcribeLanguage: String = "zh"
  var transcribeModel: String = "whisper-large-v3-turbo"
  var transcribePrompt: String = VoicePrompts.transcribeZhTW
  var cleanupEnabled: Bool = true
  var cleanupModel: String = "llama-3.3-70b-versatile"
  var cleanupChatGPTModel: String = "gpt-5-5"
  var cleanupPrompt: String = VoicePrompts.defaultCleanup
  var cleanupLanguage: String = "zh-TW"
  var maxRecordingSeconds: Int = 60
  var playSounds: Bool = true
  var noActiveClient: VoiceNoClientFallback = .clipboard
}

/// Loads the merged snapshot and persists UI edits to UserDefaults.
enum VoiceConfig {
  static let settingsChanged = Notification.Name("SquirrelVoiceSettingsChangedNotification")

  // UserDefaults keys, namespaced to avoid clashing with Squirrel defaults.
  enum Key: String, CaseIterable {
    case enabled = "voice.enabled"
    case backend = "voice.backend"
    case cookiesPath = "voice.cookiesPath"
    case hotkeyMode = "voice.hotkeyMode"
    case hotkeyEngine = "voice.hotkeyEngine"
    case trigger = "voice.trigger"
    case customKeyCode = "voice.customKeyCode"
    case customModifiers = "voice.customModifiers"
    case transcribeLanguage = "voice.transcribeLanguage"
    case transcribeModel = "voice.transcribeModel"
    case transcribePrompt = "voice.transcribePrompt"
    case cleanupEnabled = "voice.cleanupEnabled"
    case cleanupModel = "voice.cleanupModel"
    case cleanupChatGPTModel = "voice.cleanupChatGPTModel"
    case cleanupPrompt = "voice.cleanupPrompt"
    case cleanupLanguage = "voice.cleanupLanguage"
    case maxRecordingSeconds = "voice.maxRecordingSeconds"
    case playSounds = "voice.playSounds"
    case noActiveClient = "voice.noActiveClient"
  }

  /// Merge UserDefaults > squirrel.yaml > hard defaults.
  static func load(config: SquirrelConfig?) -> VoiceSettings {
    var s = VoiceSettings()
    let d = UserDefaults.standard

    func str(_ key: Key, _ yamlPath: String, _ fallback: String) -> String {
      if let v = d.string(forKey: key.rawValue), !v.isEmpty { return v }
      if let v = config?.getString(yamlPath), !v.isEmpty { return v }
      return fallback
    }
    func bool(_ key: Key, _ yamlPath: String, _ fallback: Bool) -> Bool {
      if d.object(forKey: key.rawValue) != nil { return d.bool(forKey: key.rawValue) }
      return config?.getBool(yamlPath) ?? fallback
    }
    func int(_ key: Key, _ yamlPath: String, _ fallback: Int) -> Int {
      if let v = d.object(forKey: key.rawValue) as? Int { return v }
      if let v = config?.getDouble(yamlPath) { return Int(v) }
      return fallback
    }

    s.enabled = bool(.enabled, "voice_input/enabled", s.enabled)
    s.backend = VoiceBackend(rawValue: str(.backend, "voice_input/backend", s.backend.rawValue)) ?? .groq
    s.cookiesPath = str(.cookiesPath, "voice_input/chatgpt/cookies_path", s.cookiesPath)
    s.hotkeyMode = str(.hotkeyMode, "voice_input/hotkey/mode", s.hotkeyMode)
    s.hotkeyEngine = str(.hotkeyEngine, "voice_input/hotkey/engine", s.hotkeyEngine)
    s.trigger = VoiceTriggerKind(rawValue: str(.trigger, "voice_input/hotkey/modifier", s.trigger.rawValue)) ?? .rightOption
    s.customKeyCode = int(.customKeyCode, "voice_input/hotkey/key_code", s.customKeyCode)
    s.transcribeLanguage = str(.transcribeLanguage, "voice_input/transcribe/language", s.transcribeLanguage)
    s.transcribeModel = str(.transcribeModel, "voice_input/transcribe/model", s.transcribeModel)
    // Prompt and cleanup-language defaults follow the selected language
    // (SPEC §19.1); user/yaml overrides win as usual.
    s.transcribePrompt = str(.transcribePrompt, "voice_input/transcribe/prompt",
                             VoicePrompts.transcribeDefault(language: s.transcribeLanguage))
    s.cleanupEnabled = bool(.cleanupEnabled, "voice_input/cleanup/enabled", s.cleanupEnabled)
    s.cleanupModel = str(.cleanupModel, "voice_input/cleanup/model", s.cleanupModel)
    s.cleanupChatGPTModel = str(.cleanupChatGPTModel, "voice_input/cleanup/chatgpt_model", s.cleanupChatGPTModel)
    s.cleanupPrompt = str(.cleanupPrompt, "voice_input/cleanup/prompt",
                          VoicePrompts.cleanupDefault(language: s.transcribeLanguage))
    s.cleanupLanguage = str(.cleanupLanguage, "voice_input/cleanup/language",
                            s.transcribeLanguage == "zh" ? "zh-TW" : s.transcribeLanguage)
    s.maxRecordingSeconds = int(.maxRecordingSeconds, "voice_input/max_recording_seconds", s.maxRecordingSeconds)
    s.playSounds = bool(.playSounds, "voice_input/play_sounds", s.playSounds)
    s.noActiveClient = VoiceNoClientFallback(rawValue: str(.noActiveClient, "voice_input/no_active_client", s.noActiveClient.rawValue)) ?? .clipboard
    if let v = d.object(forKey: Key.customModifiers.rawValue) as? Int {
      s.customModifiers = UInt(v)
    }
    return s
  }

  /// Persist a UI edit and notify listeners (the running VoiceInputController).
  static func set(_ key: Key, _ value: Any?) {
    let d = UserDefaults.standard
    if let value = value {
      d.set(value, forKey: key.rawValue)
    } else {
      d.removeObject(forKey: key.rawValue)
    }
  }

  static func notifyChanged() {
    NotificationCenter.default.post(name: settingsChanged, object: nil)
  }
}
