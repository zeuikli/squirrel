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
  // Onion schema patch keys (bopomo_onionplus + _space, SPEC §15.7)
  @Published var defaultAsciiMode: Bool = false      // switches/@0/reset: false=中文 true=英文
  @Published var defaultFullShape: Bool = false      // switches/@1/reset: false=半形 true=全形
  @Published var pageSize: Int = 8                   // menu/page_size (effective in-schema)
  @Published var onionSelectLabels: Bool = true      // menu/alternative_select_labels keep/remove

  @Published var colorSchemes: [String] = []
  @Published var applying = false
  @Published var statusText = ""

  /// Schemas receiving the schema-level managed patch.
  private let onionSchemas = ["bopomo_onionplus", "bopomo_onionplus_space"]

  private var userDir: URL { SquirrelApp.userDir }
  private var squirrelCustomURL: URL { userDir.appendingPathComponent("squirrel.custom.yaml") }
  private func schemaCustomURL(_ schemaID: String) -> URL {
    userDir.appendingPathComponent("\(schemaID).custom.yaml")
  }

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
    // Schema-level values live in the compiled schema config, which isn't
    // reachable through the base config — read the managed block instead.
    if let content = try? String(contentsOf: schemaCustomURL(onionSchemas[0]), encoding: .utf8) {
      let managed = RimeCustomPatcher.managedSettings(in: content)
      if let v = managed["switches/@0/reset"] { defaultAsciiMode = v == "1" }
      if let v = managed["switches/@1/reset"] { defaultFullShape = v == "1" }
      if let v = managed["menu/page_size"], let n = Int(v) { pageSize = n }
      if managed["menu/alternative_select_labels"] != nil { onionSelectLabels = false }
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
    // Schema-level patch: switch defaults + candidate menu (SPEC §15.7).
    // page_size goes here (not default.custom.yaml) — the schema's own menu
    // (included from element_bopomo) would shadow a default.yaml value.
    var schemaSettings: [String: Any] = [
      "switches/@0/reset": defaultAsciiMode ? 1 : 0,
      "switches/@1/reset": defaultFullShape ? 1 : 0,
      "menu/page_size": pageSize
    ]
    if !onionSelectLabels {
      // YAML null deletes the node → falls back to plain numeric labels.
      schemaSettings["menu/alternative_select_labels"] = NSNull()
    }

    do {
      try writePatch(url: squirrelCustomURL, settings: squirrelSettings, template: nil)
      for schema in onionSchemas {
        try writePatch(url: schemaCustomURL(schema), settings: schemaSettings, template: nil)
      }
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

  /// Open the Rime folder (the classic way — kept available from the UI too).
  func openRimeFolder() {
    NSWorkspace.shared.open(userDir)
  }
}
