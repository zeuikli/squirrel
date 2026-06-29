//
//  HotkeyManager.swift
//  Squirrel
//
//  Global push-to-talk with two interchangeable engines (SPEC §15.9):
//   - `.nsevent` (default): NSEvent global+local monitors. Needs only
//     Accessibility. Listen-only — cannot consume events.
//   - `.cgtap`: CGEventTap (LizardType port). Additionally needs Input
//     Monitoring (whose TCC record may need a remove/re-add in System
//     Settings after signature changes), but is the only path that could
//     ever consume events.
//  Two trigger styles:
//   - `.modifier`: hold a single modifier key (e.g. Right ⌥).
//   - `.keyCombo`: hold an arbitrary key + modifiers (e.g. ⌃⌥Space).
//  Press-and-hold → `onStart`; release → `onStop`.
//

import Foundation
import AppKit
import CoreGraphics

final class HotkeyManager {

  enum Engine: String {
    case nsevent
    case cgtap
  }

  enum Trigger {
    case modifier(VoiceTriggerKind)
    case keyCombo(keyCode: Int64, mods: CGEventFlags)
  }

  static let stdNSMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
  static let stdCGMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

  var onStart: (() -> Void)?
  var onStop: (() -> Void)?

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var active = false
  private var trigger: Trigger = .modifier(.rightOption)
  private(set) var engine: Engine = .nsevent

  var isInstalled: Bool { globalMonitor != nil || tap != nil }

  private func modKeyCode(_ t: VoiceTriggerKind) -> Int64 {
    switch t {
    case .rightOption:  return 61
    case .rightCommand: return 54
    case .rightControl: return 62
    case .fn:           return 63
    }
  }
  private func modNSFlag(_ t: VoiceTriggerKind) -> NSEvent.ModifierFlags {
    switch t {
    case .rightOption:  return .option
    case .rightCommand: return .command
    case .rightControl: return .control
    case .fn:           return .function
    }
  }
  private func modCGMask(_ t: VoiceTriggerKind) -> CGEventFlags {
    switch t {
    case .rightOption:  return .maskAlternate
    case .rightCommand: return .maskCommand
    case .rightControl: return .maskControl
    case .fn:           return .maskSecondaryFn
    }
  }

  private static func nsFlags(_ cg: CGEventFlags) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if cg.contains(.maskCommand) { f.insert(.command) }
    if cg.contains(.maskAlternate) { f.insert(.option) }
    if cg.contains(.maskControl) { f.insert(.control) }
    if cg.contains(.maskShift) { f.insert(.shift) }
    return f
  }

  @discardableResult
  func start(trigger: Trigger, engine: Engine = .nsevent) -> Bool {
    self.trigger = trigger
    self.engine = engine
    stop()
    let ok: Bool
    switch engine {
    case .nsevent: ok = startMonitors()
    case .cgtap:   ok = startTap()
    }
    NSLog("[SquirrelVoice] hotkey installed=%@ engine=%@", ok ? "YES" : "NO", engine.rawValue)
    return ok
  }

  func updateTrigger(_ t: Trigger, engine: Engine) {
    if isInstalled || self.engine != engine {
      start(trigger: t, engine: engine)
    } else {
      trigger = t
      self.engine = engine
    }
  }

  func stop() {
    if let m = globalMonitor { NSEvent.removeMonitor(m) }
    if let m = localMonitor { NSEvent.removeMonitor(m) }
    globalMonitor = nil
    localMonitor = nil
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
    tap = nil
    runLoopSource = nil
    active = false
  }

  // MARK: - NSEvent engine

  private func startMonitors() -> Bool {
    let mask: NSEvent.EventTypeMask
    switch trigger {
    case .modifier: mask = [.flagsChanged]
    case .keyCombo: mask = [.keyDown, .keyUp]
    }
    // Global monitors deliver nothing without Accessibility trust.
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handleNSEvent(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handleNSEvent(event)
      return event   // never consume
    }
    return globalMonitor != nil
  }

  private func handleNSEvent(_ event: NSEvent) {
    switch trigger {
    case .modifier(let t):
      guard event.type == .flagsChanged, event.keyCode == UInt16(modKeyCode(t)) else { return }
      setActive(event.modifierFlags.contains(modNSFlag(t)))

    case .keyCombo(let keyCode, let mods):
      guard event.keyCode == UInt16(keyCode) else { return }
      let want = Self.nsFlags(mods).intersection(Self.stdNSMask)
      let have = event.modifierFlags.intersection(Self.stdNSMask)
      if event.type == .keyDown {
        if have == want, !active { setActive(true) }
      } else if event.type == .keyUp {
        if active { setActive(false) }
      }
    }
  }

  // MARK: - CGEventTap engine

  private func startTap() -> Bool {
    let mask: CGEventMask
    switch trigger {
    case .modifier:
      mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    case .keyCombo:
      mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
    }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    // listen-only: active taps are gated far more strictly by macOS.
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .listenOnly, eventsOfInterest: mask,
      callback: { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        mgr.handleTapEvent(type: type, event: event)
        return Unmanaged.passUnretained(event)
      },
      userInfo: refcon
    ) else {
      return false
    }
    self.tap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = src
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  private func handleTapEvent(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      // macOS disables taps under load — re-enable so push-to-talk keeps working.
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }
    switch trigger {
    case .modifier(let t):
      guard type == .flagsChanged else { return }
      let kc = event.getIntegerValueField(.keyboardEventKeycode)
      guard kc == modKeyCode(t) else { return }
      setActive(event.flags.contains(modCGMask(t)))

    case .keyCombo(let keyCode, let mods):
      let kc = event.getIntegerValueField(.keyboardEventKeycode)
      guard kc == keyCode else { return }
      let want = mods.intersection(Self.stdCGMask)
      let have = event.flags.intersection(Self.stdCGMask)
      if type == .keyDown {
        if have == want, !active { setActive(true) }
      } else if type == .keyUp {
        if active { setActive(false) }
      }
    }
  }

  // MARK: - Shared

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
