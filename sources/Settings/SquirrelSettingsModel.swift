//
//  SquirrelSettingsModel.swift
//  Squirrel
//
//  Backing model for the General settings tab (SPEC §15). Reads effective
//  values from the compiled Rime config (SquirrelConfig), writes them back as
//  a managed patch block in ~/Library/Rime/{squirrel,default}.custom.yaml via
//  RimeCustomPatcher, then triggers a redeploy.
//

import AppKit
import Combine

@MainActor
final class SquirrelSettingsModel: ObservableObject {
  // squirrel.custom.yaml keys
  @Published var colorScheme: String = "native"
  @Published var fontFace: String = ""
  @Published var fontPoint: Int = 21
  @Published var candidateListLayout: String = "stacked"   // stacked | linear
  @Published var textOrientation: String = "horizontal"    // horizontal | vertical
  @Published var inlinePreedit: Bool = true
  @Published var showNotifications: String = "appropriate" // never | appropriate | always
  @Published var showStatusIcon: Bool = true
  // default.custom.yaml key
  @Published var pageSize: Int = 5

  @Published var colorSchemes: [String] = []
  @Published var applying = false
  @Published var statusText = ""

  private var userDir: URL { SquirrelApp.userDir }
  private var squirrelCustomURL: URL { userDir.appendingPathComponent("squirrel.custom.yaml") }
  private var defaultCustomURL: URL { userDir.appendingPathComponent("default.custom.yaml") }

  init() {
    loadEffectiveValues()
  }

  /// Read current effective values from the compiled config.
  func loadEffectiveValues() {
    let config = NSApp.squirrelAppDelegate.config
    colorSchemes = (config?.getMapKeys("preset_color_schemes") ?? []).sorted()
    if let v = config?.getString("style/color_scheme") { colorScheme = v }
    if let v = config?.getString("style/font_face") { fontFace = v }
    if let v = config?.getDouble("style/font_point") { fontPoint = Int(v) }
    if let v = config?.getString("style/candidate_list_layout") { candidateListLayout = v }
    if let v = config?.getString("style/text_orientation") { textOrientation = v }
    if let v = config?.getBool("style/inline_preedit") { inlinePreedit = v }
    if let v = config?.getString("show_notifications_when") { showNotifications = v }
    if let v = config?.getBool("status_icon/show") { showStatusIcon = v }
    // page_size lives in the schema/default config, not the squirrel config;
    // read the managed block as the source of truth for the UI, else default.
    if let content = try? String(contentsOf: defaultCustomURL, encoding: .utf8),
       let v = RimeCustomPatcher.managedSettings(in: content)["menu/page_size"],
       let n = Int(v) {
      pageSize = n
    }
  }

  /// Write both custom files and redeploy. Single-shot (Apply button).
  func apply() {
    guard !applying else { return }
    applying = true
    statusText = NSLocalizedString("Applying… (redeploying Rime)", comment: "Settings")

    let squirrelSettings: [String: Any] = [
      "style/color_scheme": colorScheme,
      "style/font_face": fontFace,
      "style/font_point": fontPoint,
      "style/candidate_list_layout": candidateListLayout,
      "style/text_orientation": textOrientation,
      "style/inline_preedit": inlinePreedit,
      "show_notifications_when": showNotifications,
      "status_icon/show": showStatusIcon
    ]
    let defaultSettings: [String: Any] = [
      "menu/page_size": pageSize
    ]

    do {
      try writePatch(url: squirrelCustomURL, settings: squirrelSettings, template: nil)
      // default.custom.yaml: when creating it fresh, seed from the shared
      // (bundled) copy so schema_list keeps bopomo_onionplus (SPEC §15.2).
      try writePatch(url: defaultCustomURL, settings: defaultSettings, template: sharedDefaultCustomTemplate())
    } catch {
      applying = false
      statusText = error.localizedDescription
      return
    }

    NSApp.squirrelAppDelegate.deploy()
    // Deploy runs synchronously enough for config reload; refresh shortly after.
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard let self = self else { return }
      self.loadEffectiveValues()
      self.applying = false
      self.statusText = NSLocalizedString("Applied ✓", comment: "Settings")
    }
  }

  private func writePatch(url: URL, settings: [String: Any], template: String?) throws {
    let current = try? String(contentsOf: url, encoding: .utf8)
    let updated = RimeCustomPatcher.updating(content: current, settings: settings, template: template)
    try updated.write(to: url, atomically: true, encoding: .utf8)
  }

  private func sharedDefaultCustomTemplate() -> String? {
    guard let shared = Bundle.main.sharedSupportPath else { return nil }
    return try? String(contentsOfFile: shared + "/default.custom.yaml", encoding: .utf8)
  }

  /// Open the Rime folder (the classic way — kept available from the UI too).
  func openRimeFolder() {
    NSWorkspace.shared.open(userDir)
  }
}
