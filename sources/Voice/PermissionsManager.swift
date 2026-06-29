//
//  PermissionsManager.swift
//  Squirrel
//
//  Ported from LizardType (Sources/Input/PermissionsManager.swift), minus the
//  paste-related helpers (voice text goes through the native IMK commit).
//  Microphone (TCC) + Accessibility / Input Monitoring helpers for the
//  CGEventTap hotkey.
//

import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

enum PermissionsManager {

  // MARK: Microphone
  static var micAuthorized: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  /// True while the user has never been asked — the system prompt can still
  /// be triggered by `requestMic()`. After a denial only System Settings helps.
  static var micUndetermined: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
  }

  static func requestMic() async -> Bool {
    if micAuthorized { return true }
    return await AVCaptureDevice.requestAccess(for: .audio)
  }

  // MARK: Accessibility (needed for CGEventTap hotkey)
  static var accessibilityTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// Prompts the system "grant Accessibility" dialog if not yet trusted.
  @discardableResult
  static func promptAccessibility() -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }

  static func openMicSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: Input Monitoring (needed for key-combo CGEventTaps)
  static var inputMonitoringTrusted: Bool {
    CGPreflightListenEventAccess()
  }

  @discardableResult
  static func requestInputMonitoring() -> Bool {
    CGRequestListenEventAccess()
  }

  static func openInputMonitoringSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
      NSWorkspace.shared.open(url)
    }
  }
}
