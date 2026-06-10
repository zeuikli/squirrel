//
//  RimeCustomPatcher.swift
//  Squirrel
//
//  Writes UI-managed settings into a Rime `*.custom.yaml` patch file without
//  touching the user's hand-written patches (SPEC §15.2).
//
//  The UI owns only the lines between the BEGIN/END markers, kept at the end
//  of the `patch:` block so its flat keys win over duplicates above. Keys use
//  Rime's flat path syntax: `"style/color_scheme": value`.
//
//  Pure text processing — no YAML parser (zero-dependency policy). All
//  functions are static and side-effect free for testability.
//

import Foundation

enum RimeCustomPatcher {
  static let beginMarker = "# >>> Squirrel Settings UI managed block — do not edit between markers <<<"
  static let endMarker = "# <<< end Squirrel Settings UI managed block >>>"

  /// Render a value as a YAML scalar.
  static func yamlScalar(_ value: Any) -> String {
    switch value {
    case let b as Bool: return b ? "true" : "false"
    case let i as Int: return String(i)
    case let d as Double: return String(d)
    case let s as String: return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    default: return "\"\(value)\""
    }
  }

  /// Return `content` with the managed block replaced (or inserted) so that it
  /// carries exactly `settings` (sorted by key for stable diffs). When
  /// `settings` is empty the managed block is removed.
  ///
  /// - `content`: current file content, or nil if the file doesn't exist.
  /// - `template`: used as the base when content is nil/blank (e.g. the
  ///   shared default.custom.yaml so schema_list survives; SPEC §15.2).
  static func updating(content: String?, settings: [String: Any], template: String? = nil) -> String {
    var base = content ?? ""
    if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      base = template ?? "patch:\n"
    }

    var lines = base.components(separatedBy: "\n")

    // Drop an existing managed block (inclusive of markers).
    if let begin = lines.firstIndex(where: { $0.contains(beginMarker) }) {
      let end = lines[begin...].firstIndex(where: { $0.contains(endMarker) }) ?? begin
      lines.removeSubrange(begin...min(end, lines.count - 1))
    }

    guard !settings.isEmpty else {
      return lines.joined(separator: "\n")
    }

    var block = ["  \(beginMarker)"]
    for key in settings.keys.sorted() {
      block.append("  \"\(key)\": \(yamlScalar(settings[key]!))")
    }
    block.append("  \(endMarker)")

    // Insert at the end of the `patch:` block: after the last line that is
    // indented content following `patch:`, before any subsequent top-level key.
    if let patchIdx = lines.firstIndex(where: { $0.hasPrefix("patch:") }) {
      var insertAt = patchIdx + 1
      var i = patchIdx + 1
      while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") || trimmed.hasPrefix("#") {
          if !trimmed.isEmpty { insertAt = i + 1 }
          i += 1
        } else {
          break   // next top-level key
        }
      }
      lines.insert(contentsOf: block, at: insertAt)
    } else {
      // No patch: block at all — append one.
      if lines.last?.isEmpty == false { lines.append("") }
      lines.append("patch:")
      lines.append(contentsOf: block)
    }
    return lines.joined(separator: "\n")
  }

  /// Read the settings currently stored in the managed block of `content`.
  static func managedSettings(in content: String) -> [String: String] {
    var result: [String: String] = [:]
    var inBlock = false
    for line in content.components(separatedBy: "\n") {
      if line.contains(beginMarker) { inBlock = true; continue }
      if line.contains(endMarker) { break }
      guard inBlock else { continue }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let colon = trimmed.range(of: "\": ") else { continue }
      let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<colon.lowerBound])
      var value = String(trimmed[colon.upperBound...])
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
      }
      result[key] = value
    }
    return result
  }
}
