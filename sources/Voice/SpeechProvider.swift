//
//  SpeechProvider.swift
//  Squirrel
//
//  Ported from LizardType (Sources/Bridge/SpeechProvider.swift), with the
//  transcribe model parameterized instead of read from app settings.
//

import Foundation

/// A backend that can transcribe recorded audio and (optionally) clean it up
/// with an LLM. Implemented by `GroqClient` (REST) and `ChatGPTBridge` (WebView).
@MainActor
protocol SpeechProvider: AnyObject {
  /// Transcribe the audio file. Returns the raw transcript text.
  /// `model` is the Whisper model name (ignored by backends with a fixed model).
  func transcribe(audioURL: URL, language: String, model: String) async throws -> String

  /// Run the cleanup LLM pass over `raw` using `prompt`. Returns cleaned text.
  func cleanup(raw: String, prompt: String, model: String, language: String) async throws -> String
}
