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

      Section(NSLocalizedString("Behavior", comment: "Settings")) {
        Toggle(NSLocalizedString("Inline preedit", comment: "Settings"), isOn: $model.inlinePreedit)
        Stepper(value: $model.pageSize, in: 1...10) {
          Text(String(format: NSLocalizedString("Candidates per page: %d", comment: "Settings"), model.pageSize))
        }
        Picker(NSLocalizedString("Show notifications", comment: "Settings"), selection: $model.showNotifications) {
          Text(NSLocalizedString("Never", comment: "Settings")).tag("never")
          Text(NSLocalizedString("When appropriate", comment: "Settings")).tag("appropriate")
          Text(NSLocalizedString("Always", comment: "Settings")).tag("always")
        }
        Toggle(NSLocalizedString("Show menu bar icon", comment: "Settings"), isOn: $model.showStatusIcon)
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
