//
//  GeneralSettingsView.swift
//  Squirrel
//
//  General (appearance / behavior) tab of the Preferences window (SPEC §15).
//  Edits accumulate locally and are written + deployed on Apply — deploy is a
//  full Rime redeploy, so it is deliberately single-shot (SPEC §15.6).
//

import SwiftUI

struct GeneralSettingsView: View {
  @ObservedObject var model: SquirrelSettingsModel

  var body: some View {
    Form {
      Section(NSLocalizedString("Appearance", comment: "Settings")) {
        Picker(NSLocalizedString("Color scheme", comment: "Settings"), selection: $model.colorScheme) {
          ForEach(model.colorSchemes, id: \.self) { Text($0).tag($0) }
        }
        TextField(NSLocalizedString("Font", comment: "Settings"), text: $model.fontFace,
                  prompt: Text(NSLocalizedString("System default", comment: "Settings")))
        Stepper(value: $model.fontPoint, in: 10...48) {
          Text(String(format: NSLocalizedString("Font size: %d", comment: "Settings"), model.fontPoint))
        }
        Picker(NSLocalizedString("Candidate layout", comment: "Settings"), selection: $model.candidateListLayout) {
          Text(NSLocalizedString("Stacked", comment: "Settings")).tag("stacked")
          Text(NSLocalizedString("Linear", comment: "Settings")).tag("linear")
        }
        Picker(NSLocalizedString("Text orientation", comment: "Settings"), selection: $model.textOrientation) {
          Text(NSLocalizedString("Horizontal", comment: "Settings")).tag("horizontal")
          Text(NSLocalizedString("Vertical", comment: "Settings")).tag("vertical")
        }
      }

      Section(NSLocalizedString("Input schema (洋蔥注音)", comment: "Settings")) {
        Picker(NSLocalizedString("Default mode", comment: "Settings"), selection: $model.defaultAsciiMode) {
          Text(NSLocalizedString("中文", comment: "Settings")).tag(false)
          Text(NSLocalizedString("英文", comment: "Settings")).tag(true)
        }
        Picker(NSLocalizedString("Default shape", comment: "Settings"), selection: $model.defaultFullShape) {
          Text(NSLocalizedString("半形", comment: "Settings")).tag(false)
          Text(NSLocalizedString("全形", comment: "Settings")).tag(true)
        }
        Stepper(value: $model.pageSize, in: 1...10) {
          Text(String(format: NSLocalizedString("Candidates per page: %d", comment: "Settings"), model.pageSize))
        }
        Toggle(NSLocalizedString("Onion select labels (⒈𝚀𝚈 ⒉𝙰𝙷 …)", comment: "Settings"), isOn: $model.onionSelectLabels)
        if model.onionSelectLabels && model.pageSize != 8 {
          Text(NSLocalizedString("⚠︎ Onion labels define 8 entries — set candidates per page to 8 to avoid display bugs.", comment: "Settings"))
            .font(.footnote)
            .foregroundColor(.orange)
        }
      }

      Section(NSLocalizedString("Behavior", comment: "Settings")) {
        Toggle(NSLocalizedString("Inline preedit", comment: "Settings"), isOn: $model.inlinePreedit)
        Picker(NSLocalizedString("Show notifications", comment: "Settings"), selection: $model.showNotifications) {
          Text(NSLocalizedString("Never", comment: "Settings")).tag("never")
          Text(NSLocalizedString("When appropriate", comment: "Settings")).tag("appropriate")
          Text(NSLocalizedString("Always", comment: "Settings")).tag("always")
        }
        Toggle(NSLocalizedString("Show menu bar icon", comment: "Settings"), isOn: $model.showStatusIcon)
      }

      Section(NSLocalizedString("Sync", comment: "Settings")) {
        Toggle(NSLocalizedString("iCloud sync (user dictionary & settings backup)", comment: "Settings"),
               isOn: $model.iCloudSyncEnabled)
          .onChange(of: model.iCloudSyncEnabled) { on in model.setICloudSync(on) }
        HStack {
          Button(NSLocalizedString("Sync now", comment: "Settings")) { model.syncNow() }
          Text(model.syncStatusText).foregroundColor(.secondary)
        }
        Text(NSLocalizedString("Syncs Rime user data via iCloud Drive (RimeSync folder). Enable this on every Mac that should share the dictionary.", comment: "Settings"))
          .font(.footnote)
          .foregroundColor(.secondary)
      }

      Section {
        HStack {
          Button(NSLocalizedString("Apply (redeploy)", comment: "Settings")) { model.apply() }
            .disabled(model.applying)
          Button(NSLocalizedString("Reload current values", comment: "Settings")) { model.loadEffectiveValues() }
          Button(NSLocalizedString("Open Rime folder…", comment: "Settings")) { model.openRimeFolder() }
          Text(model.statusText).foregroundColor(.secondary)
        }
        Text(NSLocalizedString("Settings are saved as a managed block in ~/Library/Rime/squirrel.custom.yaml — hand-written patches outside the block are preserved.", comment: "Settings"))
          .font(.footnote)
          .foregroundColor(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 480, minHeight: 420)
  }
}
