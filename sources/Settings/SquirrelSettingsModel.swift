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
  // Default/active schema picker (SPEC §22): writes default.custom.yaml.
  @Published var defaultSchema: String = "bopomo_onionplus"

  /// A bundled schema option for the picker. A proper Identifiable type —
  /// SwiftUI ForEach over a tuple array silently fails to render.
  struct SchemaOption: Identifiable {
    let id: String
    let name: String
  }

  /// Schemas bundled by this distro (id → display name). Fixed list — avoids
  /// reading each schema.yaml at runtime just for its name.
  static let bundledSchemas: [SchemaOption] = [
    SchemaOption(id: "bopomo_onionplus", name: "洋蔥注音 plus"),
    SchemaOption(id: "bopomo_onionplus_space", name: "洋蔥注音 plus（空格選字）"),
    SchemaOption(id: "bo_mixin1", name: "洋蔥注音 mix-in 1〔拉日 ˇ ˋ 韓〕"),
    SchemaOption(id: "bo_mixin2", name: "洋蔥注音 mix-in 2〔小大平片韓〕"),
    SchemaOption(id: "bo_mixin3", name: "洋蔥注音 mix-in 3〔' [ ] →拉日韓〕"),
    SchemaOption(id: "bo_mixin4", name: "洋蔥注音 mix-in 4〔全 ˊ ˇ ˋ ˙〕"),
    SchemaOption(id: "terra_pinyin", name: "地球拼音")
  ]

  @Published var colorSchemes: [String] = []
  @Published var applying = false
  @Published var statusText = ""
  // iCloud sync via Rime's native sync_dir (SPEC §18)
  @Published var iCloudSyncEnabled = false
  @Published var syncStatusText = ""

  /// Schemas receiving the schema-level managed patch (default mode/shape,
  /// page_size, select labels). All six share element_bopomo:/menu and the
  /// same switch order, so the patch applies uniformly — including the mix-in
  /// schemas, so their select labels toggle off exactly like plus (SPEC §22.5).
  private let onionSchemas = ["bopomo_onionplus", "bopomo_onionplus_space",
                              "bo_mixin1", "bo_mixin2", "bo_mixin3", "bo_mixin4"]

  private var userDir: URL { SquirrelApp.userDir }
  private var squirrelCustomURL: URL { userDir.appendingPathComponent("squirrel.custom.yaml") }
  private var defaultCustomURL: URL { userDir.appendingPathComponent("default.custom.yaml") }
  private var installationYamlURL: URL { userDir.appendingPathComponent("installation.yaml") }
  private func schemaCustomURL(_ schemaID: String) -> URL {
    userDir.appendingPathComponent("\(schemaID).custom.yaml")
  }

  private static let cloudDocsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
  static let iCloudSyncURL = cloudDocsURL.appendingPathComponent("RimeSync")

  init() {
    loadEffectiveValues()
    loadSyncState()
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
    defaultSchema = readDefaultSchema() ?? Self.bundledSchemas[0].id
  }

  /// First `- schema: <id>` entry in the user's default.custom.yaml (the
  /// current default schema), or nil if the file/entry is absent.
  private func readDefaultSchema() -> String? {
    guard let content = try? String(contentsOf: defaultCustomURL, encoding: .utf8) else { return nil }
    for line in content.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("- schema:") {
        let id = trimmed.dropFirst("- schema:".count).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
      }
    }
    return nil
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
      try writeSchemaList()
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

  /// Regenerate default.custom.yaml with the selected schema first (SPEC §22).
  /// This file is distro-owned (it only carries schema_list) so it is rewritten
  /// wholesale — unlike squirrel.custom.yaml, hand edits here are not preserved.
  private func writeSchemaList() throws {
    let ids = [defaultSchema] + Self.bundledSchemas.map(\.id).filter { $0 != defaultSchema }
    var lines = ["# 洋蔥注音方案清單（偏好設定 UI 管理，第一項為預設方案 — SPEC §22）",
                 "patch:",
                 "  schema_list:"]
    lines += ids.map { "    - schema: \($0)" }
    try (lines.joined(separator: "\n") + "\n")
      .write(to: defaultCustomURL, atomically: true, encoding: .utf8)
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

  // MARK: - iCloud sync (SPEC §18)

  /// Reflect whether installation.yaml currently points sync_dir at iCloud.
  func loadSyncState() {
    let content = (try? String(contentsOf: installationYamlURL, encoding: .utf8)) ?? ""
    iCloudSyncEnabled = content
      .components(separatedBy: "\n")
      .contains { $0.hasPrefix("sync_dir:") }
  }

  /// Toggle handler. Rewrites installation.yaml; takes effect on the next
  /// sync (sync_user_data re-runs installation_update first) — no redeploy.
  func setICloudSync(_ on: Bool) {
    if on {
      guard FileManager.default.fileExists(atPath: Self.cloudDocsURL.path) else {
        iCloudSyncEnabled = false
        syncStatusText = NSLocalizedString("iCloud Drive is not available on this Mac", comment: "Settings")
        return
      }
      try? FileManager.default.createDirectory(at: Self.iCloudSyncURL, withIntermediateDirectories: true)
    }
    do {
      try writeSyncDir(on ? Self.iCloudSyncURL.path : nil)
      syncStatusText = on
        ? NSLocalizedString("iCloud sync enabled", comment: "Settings")
        : NSLocalizedString("iCloud sync disabled (local sync folder)", comment: "Settings")
    } catch {
      syncStatusText = error.localizedDescription
      loadSyncState()
    }
  }

  func syncNow() {
    NSApp.squirrelAppDelegate.syncUserData()
    syncStatusText = NSLocalizedString("Sync started — running in background", comment: "Settings")
  }

  /// Line-level edit of installation.yaml: drop any sync_dir line, append the
  /// new one (quoted — the iCloud path contains spaces). Other keys
  /// (installation_id…) are left untouched; librime preserves sync_dir when
  /// it rewrites the file (deployment_tasks.cc InstallationUpdate).
  private func writeSyncDir(_ path: String?) throws {
    var lines = ((try? String(contentsOf: installationYamlURL, encoding: .utf8)) ?? "")
      .components(separatedBy: "\n")
      .filter { !$0.hasPrefix("sync_dir:") }
    while lines.last?.isEmpty == true { lines.removeLast() }
    if let path = path {
      lines.append("sync_dir: \"\(path)\"")
    }
    try (lines.joined(separator: "\n") + "\n")
      .write(to: installationYamlURL, atomically: true, encoding: .utf8)
  }
}
