//
//  VoiceSettingsWindow.swift
//  Squirrel
//
//  The Preferences window: a TabView hosting the General (Squirrel) tab and
//  the Voice tab (SPEC §14.2, §15.4). Squirrel is an `.accessory` IME
//  process, so opening the window temporarily switches the activation policy
//  to `.regular` for focus, and restores `.accessory` on close — the same
//  trick Sparkle's update window uses.
//

import AppKit
import SwiftUI

enum SettingsTab: Hashable {
  case general
  case voice
}

private struct SettingsRootView: View {
  @ObservedObject var generalModel: SquirrelSettingsModel
  @ObservedObject var voiceModel: VoiceSettingsModel
  @Binding var selection: SettingsTab
  var openLogin: () -> Void

  var body: some View {
    TabView(selection: $selection) {
      GeneralSettingsView(model: generalModel)
        .tabItem { Text(NSLocalizedString("General", comment: "Settings")) }
        .tag(SettingsTab.general)
      VoiceSettingsView(model: voiceModel, openLogin: openLogin)
        .tabItem { Text(NSLocalizedString("Voice", comment: "Settings")) }
        .tag(SettingsTab.voice)
    }
    .padding(.top, 4)
    .frame(minWidth: 520, minHeight: 460)
  }
}

@MainActor
final class VoiceSettingsWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var loginWindow: NSWindow?
  private var generalModel: SquirrelSettingsModel?
  private var tabSelection = TabSelectionBox()

  /// Bridges the SwiftUI tab binding to this AppKit controller.
  private final class TabSelectionBox: ObservableObject {
    @Published var tab: SettingsTab = .general
  }

  func show(tab: SettingsTab = .general) {
    if window == nil {
      let general = SquirrelSettingsModel()
      generalModel = general
      let voice = VoiceSettingsModel()
      let box = tabSelection
      let view = SettingsRootViewWrapper(box: box, generalModel: general, voiceModel: voice,
                                         openLogin: { [weak self] in self?.showLogin() })
      let host = NSHostingController(rootView: view)
      let win = NSWindow(contentViewController: host)
      win.title = NSLocalizedString("Squirrel Preferences", comment: "Settings")
      win.styleMask = [.titled, .closable, .resizable]
      win.isReleasedWhenClosed = false
      win.delegate = self
      win.center()
      window = win
    }
    tabSelection.tab = tab
    generalModel?.loadEffectiveValues()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  /// Wraps SettingsRootView so the tab selection lives in an ObservableObject
  /// this controller can drive from the menu items.
  private struct SettingsRootViewWrapper: View {
    @ObservedObject var box: TabSelectionBox
    let generalModel: SquirrelSettingsModel
    let voiceModel: VoiceSettingsModel
    var openLogin: () -> Void

    var body: some View {
      SettingsRootView(generalModel: generalModel, voiceModel: voiceModel,
                       selection: $box.tab, openLogin: openLogin)
    }
  }

  private func showLogin() {
    if loginWindow == nil {
      let view = ChatGPTLoginContainer(done: { [weak self] in
        self?.loginWindow?.close()
      })
      let host = NSHostingController(rootView: view)
      let win = NSWindow(contentViewController: host)
      win.title = NSLocalizedString("Sign in to ChatGPT", comment: "Voice settings")
      win.styleMask = [.titled, .closable, .resizable]
      win.isReleasedWhenClosed = false
      win.delegate = self
      win.center()
      loginWindow = win
    }
    loginWindow?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow else { return }
    if closing == loginWindow {
      loginWindow = nil
      return
    }
    if closing == window {
      window = nil
      generalModel = nil
      loginWindow?.close()
      // Back to a background-only IME once all our windows are gone.
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
