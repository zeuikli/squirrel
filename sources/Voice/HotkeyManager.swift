//
//  HotkeyManager.swift
//  Squirrel
//
//  Global push-to-talk. Two trigger styles:
//   - `.modifier`: hold a single modifier key (e.g. Right ⌥).
//   - `.keyCombo`: hold an arbitrary key + modifiers (e.g. ⌃⌥Space).
//  Press-and-hold → `onStart`; release → `onStop`.
//
//  Implementation note (SPEC §15.9): originally a CGEventTap port from
//  LizardType, but listen-only taps require Input Monitoring, whose TCC
//  grant macOS auto-revokes for self-signed builds. NSEvent global monitors
//  only need Accessibility, and we never consume events, so they are fully
//  equivalent here. A local monitor covers the moments our own Preferences
//  window has focus (global monitors skip events delivered to our process).
//

import Foundation
import AppKit
import CoreGraphics

final class HotkeyManager {

  enum Trigger {
    case modifier(VoiceTriggerKind)
    case keyCombo(keyCode: Int64, mods: CGEventFlags)
  }

  static let stdMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

  var onStart: (() -> Void)?
  var onStop: (() -> Void)?

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var active = false
  private var trigger: Trigger = .modifier(.rightOption)

  var isInstalled: Bool { globalMonitor != nil }

  private func modKeyCode(_ t: VoiceTriggerKind) -> UInt16 {
    switch t {
    case .rightOption:  return 61
    case .rightCommand: return 54
    case .rightControl: return 62
    case .fn:           return 63
    }
  }
  private func modFlag(_ t: VoiceTriggerKind) -> NSEvent.ModifierFlags {
    switch t {
    case .rightOption:  return .option
    case .rightCommand: return .command
    case .rightControl: return .control
    case .fn:           return .function
    }
  }

  /// Convert legacy CGEventFlags (stored in settings) to NSEvent flags.
  private static func nsFlags(_ cg: CGEventFlags) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if cg.contains(.maskCommand) { f.insert(.command) }
    if cg.contains(.maskAlternate) { f.insert(.option) }
    if cg.contains(.maskControl) { f.insert(.control) }
    if cg.contains(.maskShift) { f.insert(.shift) }
    return f
  }

  @discardableResult
  func start(trigger: Trigger) -> Bool {
    self.trigger = trigger
    stop()

    let mask: NSEvent.EventTypeMask
    switch trigger {
    case .modifier:
      mask = [.flagsChanged]
    case .keyCombo:
      mask = [.keyDown, .keyUp]
    }

    // Global monitors deliver nothing without Accessibility trust — same
    // failure mode as a CGEventTap, surfaced by the permission poll/UI.
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handle(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handle(event)
      return event   // never consume
    }
    NSLog("[SquirrelVoice] hotkey monitors installed (global=%@)", globalMonitor != nil ? "YES" : "NO")
    return globalMonitor != nil
  }

  func updateTrigger(_ t: Trigger) {
    if globalMonitor != nil { start(trigger: t) } else { trigger = t }
  }

  func stop() {
    if let m = globalMonitor { NSEvent.removeMonitor(m) }
    if let m = localMonitor { NSEvent.removeMonitor(m) }
    globalMonitor = nil
    localMonitor = nil
    active = false
  }

  private func handle(_ event: NSEvent) {
    switch trigger {
    case .modifier(let t):
      guard event.type == .flagsChanged, event.keyCode == modKeyCode(t) else { return }
      setActive(event.modifierFlags.contains(modFlag(t)))

    case .keyCombo(let keyCode, let mods):
      guard event.keyCode == UInt16(keyCode) else { return }
      let want = Self.nsFlags(mods).intersection(Self.stdMask)
      let have = event.modifierFlags.intersection(Self.stdMask)
      if event.type == .keyDown {
        if have == want, !active { setActive(true) }
      } else if event.type == .keyUp {
        if active { setActive(false) }
      }
    }
  }

  private func setActive(_ on: Bool) {
    if on && !active {
      active = true
      DispatchQueue.main.async { [weak self] in self?.onStart?() }
    } else if !on && active {
      active = false
      DispatchQueue.main.async { [weak self] in self?.onStop?() }
    }
  }
}
