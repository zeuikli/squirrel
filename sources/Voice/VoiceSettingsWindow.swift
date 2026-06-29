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
  var openGeminiLogin: () -> Void

  var body: some View {
    TabView(selection: $selection) {
      GeneralSettingsView(model: generalModel)
        .tabItem { Text(NSLocalizedString("General", comment: "Settings")) }
        .tag(SettingsTab.general)
      VoiceSettingsView(model: voiceModel, openLogin: openLogin, openGeminiLogin: openGeminiLogin)
        .tabItem { Text(NSLocalizedString("Voice", comment: "Settings")) }
        .tag(SettingsTab.voice)
    }
    .padding(.top, 4)
    .frame(minWidth: 560, minHeight: 560)
  }
}

@MainActor
final class VoiceSettingsWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var loginWindow: NSWindow?
  private var geminiLoginWindow: NSWindow?
  private var generalModel: SquirrelSettingsModel?
  private var tabSelection = TabSelectionBox()

  /// Bridges the SwiftUI tab binding to this AppKit controller.
  private final class TabSelectionBox: ObservableObject {
    @Published var tab: SettingsTab = .general
  }

  func show(tab: SettingsTab = .general) {
    Self.installEditMenuIfNeeded()
    if window == nil {
      let general = SquirrelSettingsModel()
      generalModel = general
      let voice = VoiceSettingsModel()
      let box = tabSelection
      let view = SettingsRootViewWrapper(box: box, generalModel: general, voiceModel: voice,
                                         openLogin: { [weak self] in self?.showLogin() },
                                         openGeminiLogin: { [weak self] in self?.showGeminiLogin() })
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
    var openGeminiLogin: () -> Void

    var body: some View {
      SettingsRootView(generalModel: generalModel, voiceModel: voiceModel,
                       selection: $box.tab, openLogin: openLogin, openGeminiLogin: openGeminiLogin)
    }
  }

  /// Squirrel is a background `.accessory` IME with no main menu, so the
  /// standard ⌘C/⌘V/⌘X/⌘A key equivalents never reach the focused text field
  /// in our windows (SPEC §24). Install a minimal Edit menu once — its key
  /// equivalents route cut:/copy:/paste:/selectAll:/undo:/redo: through the
  /// responder chain when a Preferences window is key.
  private static func installEditMenuIfNeeded() {
    guard NSApp.mainMenu == nil else { return }
    let mainMenu = NSMenu()

    // First item is treated as the app menu; keep it minimal.
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu()
    mainMenu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: "Menu"))
    editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: "Menu"),
                     action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: NSLocalizedString("Redo", comment: "Menu"),
                                action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: "Menu"),
                     action: Selector(("cut:")), keyEquivalent: "x")
    editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: "Menu"),
                     action: Selector(("copy:")), keyEquivalent: "c")
    editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: "Menu"),
                     action: Selector(("paste:")), keyEquivalent: "v")
    editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: "Menu"),
                     action: Selector(("selectAll:")), keyEquivalent: "a")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    NSApp.mainMenu = mainMenu
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

  private func showGeminiLogin() {
    if geminiLoginWindow == nil {
      let view = GeminiLoginContainer(done: { [weak self] in
        self?.geminiLoginWindow?.close()
      })
      let host = NSHostingController(rootView: view)
      let win = NSWindow(contentViewController: host)
      win.title = NSLocalizedString("Sign in to Gemini", comment: "Voice settings")
      win.styleMask = [.titled, .closable, .resizable]
      win.isReleasedWhenClosed = false
      win.delegate = self
      win.center()
      geminiLoginWindow = win
    }
    geminiLoginWindow?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow else { return }
    if closing == loginWindow {
      loginWindow = nil
      // Snapshot the just-completed login to the self-managed store (SPEC §4.8).
      Task { await ChatGPTBridge.persistSharedSession() }
      return
    }
    if closing == geminiLoginWindow {
      geminiLoginWindow = nil
      Task { await GeminiWebBridge.persistSharedSession() }
      return
    }
    if closing == window {
      window = nil
      generalModel = nil
      loginWindow?.close()
      geminiLoginWindow?.close()
      // Back to a background-only IME once all our windows are gone.
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
