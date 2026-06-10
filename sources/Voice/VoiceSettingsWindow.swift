//
//  VoiceSettingsWindow.swift
//  Squirrel
//
//  Hosts the SwiftUI settings form in a standalone window (SPEC §14.2).
//  Squirrel is an `.accessory` IME process, so opening the window temporarily
//  switches the activation policy to `.regular` for focus, and restores
//  `.accessory` on close — the same trick Sparkle's update window uses
//  (see SquirrelApplicationDelegate.standardUserDriverWillHandleShowingUpdate).
//

import AppKit
import SwiftUI

@MainActor
final class VoiceSettingsWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var loginWindow: NSWindow?

  func show() {
    if window == nil {
      let model = VoiceSettingsModel()
      let view = VoiceSettingsView(model: model, openLogin: { [weak self] in self?.showLogin() })
      let host = NSHostingController(rootView: view)
      let win = NSWindow(contentViewController: host)
      win.title = NSLocalizedString("Voice Input Settings", comment: "Voice settings")
      win.styleMask = [.titled, .closable, .resizable]
      win.isReleasedWhenClosed = false
      win.delegate = self
      win.center()
      window = win
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
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
      loginWindow?.close()
      // Back to a background-only IME once all our windows are gone.
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
