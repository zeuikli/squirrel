//
//  ChatGPTLoginView.swift
//  Squirrel
//
//  Visible ChatGPT login and experimental GPT Live diagnostics.  The WebView
//  owns the authenticated browser session; native code never reads cookies,
//  bearer tokens, SDP bodies, or raw WebRTC packets.
//
// The injected WebRTC observer and its lifecycle state machine intentionally
// remain together so teardown ordering stays auditable.
// swiftlint:disable file_length type_body_length cyclomatic_complexity

import SwiftUI
import WebKit

@MainActor
final class ChatGPTLiveProtocolLog {
  static let shared = ChatGPTLiveProtocolLog()
  let url: URL

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Squirrel", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    url = base.appendingPathComponent("squirrel-gpt-live.log")
  }

  func write(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: data)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch { }
  }

  /// Page-world messages are untrusted even when they originated from our
  /// injected observer. Keep only the fixed protocol schemas and a tiny ASCII
  /// metadata alphabet so a changed/malicious page cannot inject transcript,
  /// credentials, or extra log lines into the native safe log.
  func writePageProtocol(_ raw: String, surface: String? = nil) {
    guard Self.isAllowedPageProtocol(raw) else { return }
    let safe = String(raw.unicodeScalars.prefix(320).map { scalar in
      Self.isSafeProtocolScalar(scalar) ? Character(String(scalar)) : "_"
    })
    guard !safe.isEmpty else { return }
    write((surface.map { "surface=\($0) " } ?? "") + safe)
  }

  func writePageState(kind: String, value: String, surface: String? = nil) {
    guard Self.isAllowedPageState(kind: kind, value: value) else { return }
    write((surface.map { "surface=\($0) " } ?? "") + "ui.\(kind) value=\(value)")
  }

  private static func isAllowedPageProtocol(_ value: String) -> Bool {
    guard value.unicodeScalars.count <= 320 else { return false }
    let patterns = [
      "^http method=POST path=/realtime/wm phase=request$",
      "^http method=POST path=/realtime/wm status=[0-9]{3} duration_ms=[0-9]{1,9}$",
      "^http method=POST path=/realtime/wm result=network_error error=(Error|TypeError|AbortError|NetworkError|NotAllowedError|NotFoundError|InvalidStateError|OperationError|unknown)$",
      "^webrtc pc=constructed$",
      "^webrtc createOffer=(call|resolved type=(offer|answer|pranswer|rollback|unknown)|rejected error=(Error|TypeError|AbortError|NetworkError|NotAllowedError|NotFoundError|InvalidStateError|OperationError|unknown))$",
      "^webrtc setLocalDescription=(call type=(offer|answer|pranswer|rollback|unknown)|resolved signaling=(stable|have-local-offer|have-remote-offer|have-local-pranswer|have-remote-pranswer|closed|unknown) gathering=(new|gathering|complete|unknown)|rejected error=(Error|TypeError|AbortError|NetworkError|NotAllowedError|NotFoundError|InvalidStateError|OperationError|unknown))$",
      "^webrtc peer=(new|connecting|connected|disconnected|failed|closed|unknown) ice=(new|checking|connected|completed|disconnected|failed|closed|unknown)$",
      "^datachannel state=(open|closed|error)$",
      "^media\\.gum phase=call visible=(visible|hidden|prerender|unloaded) focus=(true|false) activation=(true|false)$",
      "^media\\.gum phase=resolved duration_ms=[0-9]{1,9} tracks=[0-9]{1,3} kinds=(none|audio|video|audio,audio|audio,video|video,audio|video,video)$",
      "^media\\.gum phase=rejected duration_ms=[0-9]{1,9} error=(Error|TypeError|AbortError|NetworkError|NotAllowedError|NotFoundError|InvalidStateError|OperationError|unknown)$",
      "^event type=(state_update|startup_telemetry|chat_message_delta|usage_update|conversation_update|spawn_update|data_message|json_event|text_data-channel_message|binary_data-channel_message|unknown)$",
      "^transcript result=(deferred reason=utterance_not_finished chars=[0-9]{1,9}|fallback_after_release_settle chars=[0-9]{1,9})$",
      "^transcript source=datachannel result=ignored reason=(role_not_user|no_user_transcript_field)$",
      "^transcript source=datachannel role=user final=true chars=[0-9]{1,9} text=\\[REDACTED\\]$",
      "^transcript source=dom stable_ms=1500 chars=[0-9]{1,9} text=\\[REDACTED\\]$",
      "^page\\.(error|rejection) name=(Error|TypeError|AbortError|NetworkError|NotAllowedError|NotFoundError|InvalidStateError|OperationError|unknown)$",
      "^voice\\.config result=session_mutation_failed$",
      "^voice\\.config mode=(conversation|transcription_only) voice=(custom|default) mutation=(applied|not_requested|not_applicable|failed)$",
      "^voice\\.language code=zh-TW mutation=(applied|not_applicable|failed)$",
      "^voice\\.click source=script trusted=false visible=(visible|hidden|prerender|unloaded) focus=(true|false) activation=(true|false)$",
      "^voice\\.utterance phase=(finish muted_tracks=[0-9]{1,3}|start enabled_tracks=[0-9]{1,3})$",
      "^voice\\.ui_end result=(clicked selector=\\[REDACTED_STABLE_SELECTOR\\]|not_found|click_failed)$",
      "^voice\\.session result=closed$",
      "^voice\\.shutdown ui_end=(clicked|not_found|click_failed)$"
    ]
    return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
  }

  private static func isSafeProtocolScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 32, 45, 46, 47, 58, 61, 91, 93, 95,
         48...57, 65...90, 97...122:
      return true
    default:
      return false
    }
  }

  private static func isAllowedPageState(kind: String, value: String) -> Bool {
    switch kind {
    case "signaling":
      return value.range(of: "^HTTP [0-9]{3} (connected|failed)$", options: .regularExpression) != nil
    case "peer":
      return ["new", "connecting", "connected", "disconnected", "failed", "closed"].contains(value)
    case "channel":
      return ["data: connecting", "data: open", "data: closed", "data: error"].contains(value)
    case "event":
      return ["state_update", "startup_telemetry", "chat_message_delta", "usage_update",
              "conversation_update", "spawn_update", "data_message", "json_event",
              "text_data-channel_message", "binary_data-channel_message"].contains(value)
    default:
      return false
    }
  }
}

@MainActor
final class ChatGPTLiveMonitor: ObservableObject {
  @Published var signaling = "Waiting for Voice…"
  @Published var peerConnection = "Not connected"
  @Published var dataChannel = "Not open"
  @Published var lastTranscript = ""
  @Published var lastEvent = ""
  @Published var autoInsert = true
  @Published var startVoiceRequest = 0
  @Published var voiceStartInFlight = false

  fileprivate var lastCommitted = ""
  fileprivate var insertionTarget: NSRunningApplication?
}

struct ChatGPTLoginView: NSViewRepresentable {
  var liveMonitor: ChatGPTLiveMonitor?

  init(liveMonitor: ChatGPTLiveMonitor? = nil) {
    self.liveMonitor = liveMonitor
  }

  final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    weak var monitor: ChatGPTLiveMonitor?
    var handledStartVoiceRequest = 0

    init(monitor: ChatGPTLiveMonitor?) {
      self.monitor = monitor
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
      let trustedVoiceOrigin = origin.host == "chatgpt.com" || origin.host.hasSuffix(".chatgpt.com")
      decisionHandler(trustedVoiceOrigin && type == .microphone ? .grant : .deny)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
      guard message.name == "squirrelLive",
            message.frameInfo.isMainFrame,
            Self.isTrustedChatGPTHost(message.frameInfo.securityOrigin.host),
            let payload = message.body as? [String: Any],
            let kind = payload["kind"] as? String else { return }
      Task { @MainActor [weak self] in
        guard let self, let monitor = self.monitor else { return }
        let rawValue = payload["value"] as? String ?? ""
        let value = kind == "transcript" ? rawValue : String(rawValue.prefix(500))
        switch kind {
        case "protocol":
          ChatGPTLiveProtocolLog.shared.writePageProtocol(String(value), surface: "web_test")
        case "signaling":
          monitor.signaling = String(value)
          ChatGPTLiveProtocolLog.shared.writePageState(kind: "signaling", value: String(value), surface: "web_test")
          if value.hasSuffix("failed") {
            monitor.voiceStartInFlight = false
            monitor.dataChannel = "data: error"
          }
        case "peer":
          monitor.peerConnection = String(value)
          if value == "failed" || value == "closed" {
            monitor.voiceStartInFlight = false
            monitor.dataChannel = "data: error"
          }
        case "channel":
          monitor.dataChannel = String(value)
          if value == "data: open" || value == "data: closed" || value == "data: error" {
            monitor.voiceStartInFlight = false
          }
        case "event": monitor.lastEvent = String(value)
        case "transcript":
          let transcript = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
          guard !transcript.isEmpty else { return }
          monitor.lastTranscript = transcript
          guard monitor.autoInsert, transcript != monitor.lastCommitted else { return }
          monitor.lastCommitted = transcript
          let settings = VoiceConfig.load(config: NSApp.squirrelAppDelegate.config)
          VoiceInputController.deliverLiveTranscript(transcript,
                                                     to: monitor.insertionTarget,
                                                     settings: settings)
        default: break
        }
      }
    }

    static func isTrustedChatGPTHost(_ host: String) -> Bool {
      host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      guard let url = navigationAction.request.url,
            url.scheme == "https",
            let host = url.host,
            Self.isTrustedChatGPTHost(host) || host == "openai.com" || host.hasSuffix(".openai.com")
      else {
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(monitor: liveMonitor) }

  func makeNSView(context: Context) -> WKWebView {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = ChatGPTBridge.sessionDataStore()
    if liveMonitor != nil {
      cfg.userContentController.add(context.coordinator, name: "squirrelLive")
      cfg.userContentController.addUserScript(WKUserScript(
        source: Self.liveConfigurationScript(
          settings: VoiceConfig.load(config: NSApp.squirrelAppDelegate.config),
          surface: "web_test"),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true))
      cfg.userContentController.addUserScript(WKUserScript(
        source: Self.liveMonitorScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true))
    }
    let webView = WKWebView(frame: .zero, configuration: cfg)
    webView.uiDelegate = context.coordinator
    webView.navigationDelegate = context.coordinator
    webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    return webView
  }

  static func liveConfigurationScript(settings: VoiceSettings, surface: String) -> String {
    let mode = settings.gptLiveMode.rawValue
    let voice = settings.gptLiveVoiceSlug ?? ""
    // `language` is deliberately a fixed value, not copied from the page or
    // from browser state. The injected page script applies it only to the
    // outgoing `/realtime/wm` FormData session and reports fixed metadata
    // only; native code never observes the session JSON, credentials, SDP, or
    // WebRTC payloads.
    return "window.__squirrelConfig={mode:'\(mode)',voice:'\(voice)',language:'zh-TW',surface:'\(surface)'};"
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    if liveMonitor != nil {
      // Settings can change while the diagnostic window remains open. Refresh
      // only the fixed local config object; no page credential/state is read.
      nsView.evaluateJavaScript(Self.liveConfigurationScript(
        settings: VoiceConfig.load(config: NSApp.squirrelAppDelegate.config),
        surface: "web_test"))
    }
    guard let monitor = liveMonitor,
          monitor.startVoiceRequest > context.coordinator.handledStartVoiceRequest else { return }
    context.coordinator.handledStartVoiceRequest = monitor.startVoiceRequest
    let requestID = monitor.startVoiceRequest
    monitor.voiceStartInFlight = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak monitor] in
      guard let monitor,
            monitor.startVoiceRequest == requestID,
            monitor.voiceStartInFlight else { return }
      monitor.voiceStartInFlight = false
      monitor.dataChannel = "data: error"
      ChatGPTLiveProtocolLog.shared.write(
        "surface=web_test voice.toolbar result=timeout reason=no_data_channel")
    }
    let script = #"""
    (() => {
      const button = document.querySelector('button[data-testid="composer-speech-button"], button[aria-label="Start Voice"], button[aria-label="Start voice mode"]');
      if (!button) return 'not_found';
      button.click();
      return 'clicked';
    })()
    """#
    nsView.evaluateJavaScript(script) { result, error in
      Task { @MainActor in
        let outcome = error == nil ? (result as? String ?? "unknown") : "script_error"
        if outcome != "clicked" { monitor.voiceStartInFlight = false }
        ChatGPTLiveProtocolLog.shared.write("surface=web_test voice.toolbar result=\(outcome) selector=[REDACTED_STABLE_SELECTOR]")
        if outcome == "not_found" {
          SquirrelApplicationDelegate.showMessage(
            msgText: NSLocalizedString("Voice button is not ready yet — wait for ChatGPT to finish loading", comment: "Voice"))
        }
      }
    }
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    guard coordinator.monitor != nil else { return }
    // SwiftUI's window close does not guarantee that ChatGPT's Voice surface
    // receives an End action. Stop the page resources and remove the bridge so
    // the visible test cannot retain a microphone or keep logging afterward.
    var detached = false
    let detach = {
      guard !detached else { return }
      detached = true
      nsView.stopLoading()
      nsView.navigationDelegate = nil
      nsView.uiDelegate = nil
      nsView.configuration.userContentController.removeScriptMessageHandler(forName: "squirrelLive")
      ChatGPTLiveProtocolLog.shared.write("surface=web_test voice.teardown result=dismantled")
    }
    nsView.evaluateJavaScript("window.__squirrelShutdown ? window.__squirrelShutdown('web_test_dismissed') : false") { _, _ in
      DispatchQueue.main.async(execute: detach)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: detach)
  }

  /// Observes only connection metadata and final user-visible transcript text.
  /// It deliberately never exports request headers, cookies, SDP, ICE data, or
  /// complete DataChannel payloads to Swift.
  static let liveMonitorScript = #"""
  (() => {
    if (window.__squirrelLiveInstalled) return;
    window.__squirrelLiveInstalled = true;
    const send = (kind, value) => {
      try { window.webkit.messageHandlers.squirrelLive.postMessage({kind, value: String(value || '')}); } catch (_) {}
    };
    let voiceActive = false;
    let signalingConnected = false;
    let lastTranscript = '';
    let pendingTranscript = '';
    let pendingTranscriptSource = '';
    let utteranceFinishing = false;
    let postReleaseSettleTimer = null;
    let lastEventLog = new Map();
    const knownEventTypes = new Set([
      'state_update', 'startup_telemetry', 'chat_message_delta', 'usage_update',
      'conversation_update', 'spawn_update', 'data_message', 'json_event',
      'text_data-channel_message', 'binary_data-channel_message'
    ]);
    const activeStreams = new Set();
    const activePeers = new Set();
    const connectedPeers = new Set();
    const openChannels = new Set();
    const pendingDOMTimers = new Set();
    let domObserver = null;
    let cleanupScheduled = false;
    let lastAggregateActive = false;
    const isConversationMode = () => window.__squirrelConfig && window.__squirrelConfig.mode === 'conversation';
    const isBackgroundOneShot = () => window.__squirrelConfig &&
      window.__squirrelConfig.surface === 'background' && !isConversationMode();
    const reportAggregateSession = () => {
      const active = connectedPeers.size > 0 && openChannels.size > 0;
      if (active === lastAggregateActive) return;
      lastAggregateActive = active;
      if (active) baselineCurrentUserMessages();
      send('session', active ? 'active' : 'inactive');
    };
    const applyOutputPolicy = () => {
      if (!isConversationMode()) {
        document.querySelectorAll('audio,video').forEach(element => { element.muted = true; });
      }
    };
    const stopAllCapturedMedia = () => {
      activeStreams.forEach(stream => stream.getTracks().forEach(track => track.stop()));
      activeStreams.clear();
      activePeers.forEach(pc => {
        try { pc.getSenders().forEach(sender => sender.track && sender.track.stop()); } catch (_) {}
        try { pc.getTransceivers().forEach(transceiver => transceiver.stop()); } catch (_) {}
        try { pc.close(); } catch (_) {}
      });
      activePeers.clear();
      connectedPeers.clear();
      openChannels.clear();
      reportAggregateSession();
      document.querySelectorAll('audio,video').forEach(element => {
        try {
          const stream = element.srcObject;
          if (stream && stream.getTracks) stream.getTracks().forEach(track => track.stop());
          element.srcObject = null;
        } catch (_) {}
      });
    };
    const endVoiceUI = () => {
      const closeButton = document.querySelector(
        'button[data-testid="voice-mode-close-button"], button[data-testid="voice-close-button"], ' +
        'button[aria-label="End voice mode"], button[aria-label="Exit voice mode"], ' +
        'button[aria-label="End Voice"], button[aria-label="Close voice"]');
      if (!closeButton) return 'not_found';
      try { closeButton.click(); return 'clicked'; } catch (_) { return 'click_failed'; }
    };
    window.__squirrelShutdown = reason => {
      const uiEnd = endVoiceUI();
      clearTimeout(postReleaseSettleTimer);
      postReleaseSettleTimer = null;
      pendingDOMTimers.forEach(timer => clearTimeout(timer));
      pendingDOMTimers.clear();
      if (domObserver) {
        domObserver.disconnect();
        domObserver = null;
      }
      stopAllCapturedMedia();
      voiceActive = false;
      signalingConnected = false;
      send('session', 'closed');
      send('protocol', 'voice.shutdown ui_end=' + uiEnd);
      send('protocol', 'voice.session result=closed');
      return true;
    };
    window.__squirrelFinishUtterance = () => {
      utteranceFinishing = true;
      let muted = 0;
      activeStreams.forEach(stream => stream.getAudioTracks().forEach(track => {
        if (track.enabled) { track.enabled = false; muted++; }
      }));
      activePeers.forEach(pc => {
        try {
          pc.getSenders().forEach(sender => {
            if (sender.track && sender.track.kind === 'audio' && sender.track.enabled) {
              sender.track.enabled = false;
              muted++;
            }
          });
        } catch (_) {}
      });
      if (isBackgroundOneShot()) {
        if (pendingTranscript && pendingTranscriptSource === 'datachannel') {
          const final = pendingTranscript;
          pendingTranscript = '';
          pendingTranscriptSource = '';
          publishTranscript(final, 'datachannel');
        } else {
          capturePostReleaseUserDOM();
          schedulePostReleaseFallback();
        }
      }
      send('protocol', 'voice.utterance phase=finish muted_tracks=' + muted);
      return muted;
    };
    window.__squirrelStartUtterance = () => {
      lastTranscript = '';
      pendingTranscript = '';
      pendingTranscriptSource = '';
      utteranceFinishing = false;
      clearTimeout(postReleaseSettleTimer);
      postReleaseSettleTimer = null;
      baselineCurrentUserMessages();
      let enabled = 0;
      activeStreams.forEach(stream => stream.getAudioTracks().forEach(track => {
        if (!track.enabled && track.readyState === 'live') { track.enabled = true; enabled++; }
      }));
      activePeers.forEach(pc => {
        try {
          pc.getSenders().forEach(sender => {
            if (sender.track && sender.track.kind === 'audio' && !sender.track.enabled && sender.track.readyState === 'live') {
              sender.track.enabled = true;
              enabled++;
            }
          });
        } catch (_) {}
      });
      send('protocol', 'voice.utterance phase=start enabled_tracks=' + enabled);
      return enabled;
    };
    const finishOneShotSession = () => {
      if (cleanupScheduled) return;
      cleanupScheduled = true;
      setTimeout(() => {
        const uiEnd = endVoiceUI();
        send('protocol', 'voice.ui_end result=' + uiEnd + (uiEnd === 'clicked' ? ' selector=[REDACTED_STABLE_SELECTOR]' : ''));
        stopAllCapturedMedia();
        setTimeout(stopAllCapturedMedia, 1000);
        voiceActive = false;
        signalingConnected = false;
        cleanupScheduled = false;
        send('session', 'closed');
        send('protocol', 'voice.session result=closed');
      }, 100);
    };
    const publishTranscript = (text, source = 'unknown') => {
      text = String(text || '').replace(/\s+/g, ' ').trim();
      if (!voiceActive || !text || text === lastTranscript) return;
      if (isBackgroundOneShot() && !utteranceFinishing) {
        pendingTranscript = text;
        pendingTranscriptSource = source;
        send('protocol', `transcript result=deferred reason=utterance_not_finished chars=${text.length}`);
        return;
      }
      if (isBackgroundOneShot() && source === 'dom') {
        // User DOM text can still mutate from a prefix into the final sentence
        // after Option is released. Quiet-period delivery is handled by the
        // mutation observer below; explicit DataChannel finals bypass this.
        pendingTranscript = text;
        pendingTranscriptSource = 'dom';
        schedulePostReleaseFallback();
        return;
      }
      clearTimeout(postReleaseSettleTimer);
      postReleaseSettleTimer = null;
      pendingTranscript = '';
      pendingTranscriptSource = '';
      lastTranscript = text;
      // Transport the complete user utterance to Swift. It is never sent to
      // the safe log; only the native delivery path receives this value.
      send('transcript', text);
      if (isBackgroundOneShot()) finishOneShotSession();
    };
    const schedulePostReleaseFallback = () => {
      if (!isBackgroundOneShot() || !utteranceFinishing || !pendingTranscript || lastTranscript) return;
      clearTimeout(postReleaseSettleTimer);
      // A DOM observer can see an unstable prefix before/after release. Commit
      // only after a turn-scoped 1.8s quiet period with no user-node mutation.
      postReleaseSettleTimer = setTimeout(() => {
        const fallback = pendingTranscript;
        pendingTranscript = '';
        pendingTranscriptSource = '';
        if (fallback && !lastTranscript) {
          send('protocol', `transcript result=fallback_after_release_settle chars=${fallback.length}`);
          publishTranscript(fallback, 'dom_settled');
        }
      }, 1800);
    };

    const safeErrorName = value => {
      const name = String(value || 'unknown');
      return ['Error', 'TypeError', 'AbortError', 'NetworkError', 'NotAllowedError',
              'NotFoundError', 'InvalidStateError', 'OperationError'].includes(name) ? name : 'unknown';
    };
    window.addEventListener('error', e => send('protocol', `page.error name=${safeErrorName(e.error && e.error.name)}`));
    window.addEventListener('unhandledrejection', e => send('protocol', `page.rejection name=${safeErrorName(e.reason && e.reason.name)}`));
    const mediaDevices = navigator.mediaDevices;
    if (mediaDevices && mediaDevices.getUserMedia) {
      const nativeGUM = mediaDevices.getUserMedia.bind(mediaDevices);
      mediaDevices.getUserMedia = async function(constraints) {
        const started = performance.now();
        send('protocol', `media.gum phase=call visible=${document.visibilityState} focus=${document.hasFocus()} activation=${navigator.userActivation && navigator.userActivation.isActive || false}`);
        try {
          const stream = await nativeGUM(constraints);
          const tracks = stream.getTracks();
          activeStreams.add(stream);
          send('protocol', `media.gum phase=resolved duration_ms=${Math.round(performance.now()-started)} tracks=${tracks.length} kinds=${tracks.map(t => t.kind).join(',')}`);
          return stream;
        } catch (error) {
          send('protocol', `media.gum phase=rejected duration_ms=${Math.round(performance.now()-started)} error=${error && error.name || 'unknown'}`);
          throw error;
        }
      };
    }

    const nativeFetch = window.fetch;
    window.fetch = async function(input, init) {
      const url = typeof input === 'string' ? input : (input && input.url) || '';
      const isLive = /\/realtime\/wm(?:\?|$)/.test(url);
      const started = performance.now();
      if (isLive) {
        let voiceMutation = 'not_requested';
        let languageMutation = 'not_applicable';
        try {
          const body = init && init.body;
          const rawSession = body instanceof FormData ? body.get('session') : null;
          const configuredVoice = window.__squirrelConfig && window.__squirrelConfig.voice;
          const configuredLanguage = window.__squirrelConfig && window.__squirrelConfig.language === 'zh-TW'
            ? 'zh-TW' : null;
          if (typeof rawSession === 'string') {
            const session = JSON.parse(rawSession);
            if (configuredVoice) {
              session.voice = configuredVoice;
              voiceMutation = 'applied';
            }
            if (configuredLanguage) {
              // This runs entirely inside the authenticated WebKit page. Do
              // not export, log, or otherwise inspect the rest of `session`.
              session.language_code = configuredLanguage;
              languageMutation = 'applied';
            }
            body.set('session', JSON.stringify(session));
          } else {
            if (configuredVoice) voiceMutation = 'not_applicable';
            if (configuredLanguage) languageMutation = 'not_applicable';
          }
        } catch (_) {
          voiceMutation = 'failed';
          languageMutation = 'failed';
          send('protocol', 'voice.config result=session_mutation_failed');
        }
        const mode = window.__squirrelConfig && window.__squirrelConfig.mode === 'conversation' ? 'conversation' : 'transcription_only';
        const voice = window.__squirrelConfig && window.__squirrelConfig.voice ? 'custom' : 'default';
        send('protocol', 'voice.config mode=' + mode + ' voice=' + voice + ' mutation=' + voiceMutation);
        send('protocol', 'voice.language code=zh-TW mutation=' + languageMutation);
        send('protocol', 'http method=POST path=/realtime/wm phase=request');
      }
      try {
        const response = await nativeFetch.apply(this, arguments);
        if (isLive) {
          send('signaling', `HTTP ${response.status} ${response.ok ? 'connected' : 'failed'}`);
          signalingConnected = response.ok;
          send('protocol', `http method=POST path=/realtime/wm status=${response.status} duration_ms=${Math.round(performance.now()-started)}`);
        }
        return response;
      } catch (error) {
        if (isLive) send('protocol', `http method=POST path=/realtime/wm result=network_error error=${error && error.name || 'unknown'}`);
        throw error;
      }
    };

    const observeChannel = dc => {
      if (!dc || dc.__squirrelObserved) return dc;
      dc.__squirrelObserved = true;
      send('channel', `data: ${dc.readyState || 'connecting'}`);
      dc.addEventListener('open', () => { send('channel', 'data: open'); send('protocol', 'datachannel state=open'); });
      dc.addEventListener('close', () => { voiceActive = false; send('channel', 'data: closed'); send('protocol', 'datachannel state=closed'); });
      dc.addEventListener('error', () => {
        openChannels.delete(dc);
        voiceActive = connectedPeers.size > 0 && openChannels.size > 0;
        reportAggregateSession();
        send('channel', 'data: error');
        send('protocol', 'datachannel state=error');
      });
      dc.addEventListener('open', () => {
        openChannels.add(dc);
        reportAggregateSession();
      });
      dc.addEventListener('close', () => {
        openChannels.delete(dc);
        voiceActive = connectedPeers.size > 0 && openChannels.size > 0;
        reportAggregateSession();
      });
      dc.addEventListener('message', event => {
        if (typeof event.data !== 'string') {
          send('event', 'binary data-channel message');
          return;
        }
        try {
          const outer = JSON.parse(event.data);
          let obj = outer;
          for (let depth = 0; depth < 5; depth++) {
            if (!obj || typeof obj !== 'object' || obj.type !== 'data_message' || obj.data == null) break;
            if (typeof obj.data === 'string') {
              try { obj = JSON.parse(obj.data); } catch (_) { break; }
            } else if (typeof obj.data === 'object') obj = obj.data;
            else break;
          }
          const type = String(obj && (obj.type || obj.event) || 'json event').slice(0, 160);
          const candidateType = type.replace(/[^a-zA-Z0-9._:-]/g, '_');
          const safeType = knownEventTypes.has(candidateType) ? candidateType : 'unknown';
          send('event', safeType);
          const now = Date.now();
          if (!lastEventLog.has(safeType) || now - lastEventLog.get(safeType) >= 30000) {
            lastEventLog.set(safeType, now);
            send('protocol', `event type=${safeType}`);
          }
          const lower = type.toLowerCase();
          const isFinal = /(transcript|transcription)/.test(lower) && /(complete|completed|final|done)/.test(lower);
          const roleCandidates = [
            obj && obj.role, obj && obj.author && obj.author.role,
            obj && obj.item && obj.item.role,
            obj && obj.item && obj.item.author && obj.item.author.role,
            obj && obj.payload && obj.payload.role
          ].map(value => String(value || '').toLowerCase());
          const explicitRole = roleCandidates.find(Boolean) || '';
          const typeNamesUserAudio = /(?:input[_.:-]?audio.*(?:transcript|transcription)|(?:transcript|transcription).*input[_.:-]?audio|user[_.:-].*(?:transcript|transcription)|(?:transcript|transcription).*user)/.test(lower);
          const isExplicitUserFinal = isFinal &&
            explicitRole !== 'assistant' && (explicitRole === 'user' || typeNamesUserAudio);
          if (isFinal && !isExplicitUserFinal) {
            send('protocol', 'transcript source=datachannel result=ignored reason=role_not_user');
          }
          if (isExplicitUserFinal) {
            const transcriptFrom = record => {
              if (!record || typeof record !== 'object') return '';
              const content = Array.isArray(record.item && record.item.content) ? record.item.content :
                (Array.isArray(record.content) ? record.content : []);
              const contentTranscript = content.find(item => item &&
                /input[_.:-]?audio.*(?:transcript|transcription)/.test(String(item.type || '').toLowerCase()) &&
                typeof item.transcript === 'string')?.transcript;
              return record.transcript || record.input_audio_transcription?.transcript ||
                record.item?.transcript || record.item?.input_audio_transcription?.transcript ||
                contentTranscript || '';
            };
            const candidate = transcriptFrom(obj) || transcriptFrom(obj && obj.payload);
            if (typeof candidate === 'string' && candidate.trim().length > 0) {
              send('protocol', `transcript source=datachannel role=user final=true chars=${candidate.length} text=[REDACTED]`);
              // An explicit user input-audio final is authoritative and may
              // commit immediately after release (unlike mutable DOM text).
              publishTranscript(candidate, 'datachannel');
            } else {
              send('protocol', 'transcript source=datachannel result=ignored reason=no_user_transcript_field');
            }
          }
        } catch (_) { send('event', 'text data-channel message'); }
      });
      return dc;
    };

    const NativePC = window.RTCPeerConnection;
    if (NativePC) {
      function SquirrelPC(...args) {
        const pc = new NativePC(...args);
        let lastReportedPeerTuple = '';
        activePeers.add(pc);
        pc.addEventListener('track', () => setTimeout(applyOutputPolicy, 0));
        send('protocol', 'webrtc pc=constructed');
        const nativeOffer = pc.createOffer.bind(pc);
        pc.createOffer = async (...args) => {
          send('protocol', 'webrtc createOffer=call');
          try { const offer = await nativeOffer(...args); send('protocol', `webrtc createOffer=resolved type=${offer && offer.type || 'unknown'}`); return offer; }
          catch (error) { send('protocol', `webrtc createOffer=rejected error=${error && error.name || 'unknown'}`); throw error; }
        };
        const nativeSetLocal = pc.setLocalDescription.bind(pc);
        pc.setLocalDescription = async description => {
          send('protocol', `webrtc setLocalDescription=call type=${description && description.type || 'unknown'}`);
          try { const result = await nativeSetLocal(description); send('protocol', `webrtc setLocalDescription=resolved signaling=${pc.signalingState} gathering=${pc.iceGatheringState}`); return result; }
          catch (error) { send('protocol', `webrtc setLocalDescription=rejected error=${error && error.name || 'unknown'}`); throw error; }
        };
        const nativeCreate = pc.createDataChannel.bind(pc);
        pc.createDataChannel = (...channelArgs) => observeChannel(nativeCreate(...channelArgs));
        pc.addEventListener('datachannel', event => observeChannel(event.channel));
        const report = () => {
          const state = pc.connectionState || pc.iceConnectionState || 'connecting';
          // A freshly allocated peer is not a live Voice session. Treating
          // `new` as active caused historical DOM messages to be inserted.
          if (['connecting', 'connected'].includes(state)) connectedPeers.add(pc);
          else connectedPeers.delete(pc);
          voiceActive = connectedPeers.size > 0;
          reportAggregateSession();
          const peerTuple = `${state}|${pc.connectionState || 'unknown'}|${pc.iceConnectionState || 'unknown'}`;
          if (peerTuple === lastReportedPeerTuple) return;
          lastReportedPeerTuple = peerTuple;
          send('peer', state);
          send('protocol', `webrtc peer=${pc.connectionState || 'unknown'} ice=${pc.iceConnectionState || 'unknown'}`);
        };
        pc.addEventListener('connectionstatechange', report);
        pc.addEventListener('iceconnectionstatechange', report);
        report();
        return pc;
      }
      SquirrelPC.prototype = NativePC.prototype;
      Object.setPrototypeOf(SquirrelPC, NativePC);
      window.RTCPeerConnection = SquirrelPC;
    }

    // The transcript fallback is deliberately scoped to user-authored DOM
    // messages created after the current Voice session becomes active.  ChatGPT
    // streams assistant deltas into the same page, so reading generic text nodes
    // (or historic user turns still loading) can otherwise insert the wrong text.
    const baselineUserMessages = new WeakSet();
    const domTimers = new WeakMap();
    const domPublished = new WeakMap();
    const baselineCurrentUserMessages = () => {
      document.querySelectorAll('[data-message-author-role="user"]').forEach(node => {
        baselineUserMessages.add(node);
        const timer = domTimers.get(node);
        clearTimeout(timer);
        pendingDOMTimers.delete(timer);
      });
    };
    const updatePostReleaseDOMCandidate = node => {
      if (baselineUserMessages.has(node) || !voiceActive || !signalingConnected) return;
      const candidate = String(node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
      if (!candidate) return;
      // This runs synchronously for every mutation that belongs to this user
      // node. Do not publish a partial; reset the quiet timer instead.
      pendingTranscript = candidate;
      pendingTranscriptSource = 'dom';
      schedulePostReleaseFallback();
    };
    const capturePostReleaseUserDOM = () => {
      if (!isBackgroundOneShot() || !utteranceFinishing) return;
      document.querySelectorAll('[data-message-author-role="user"]').forEach(updatePostReleaseDOMCandidate);
    };
    const scanMessages = nodes => {
      applyOutputPolicy();
      (nodes || document.querySelectorAll('[data-message-author-role="user"]')).forEach(node => {
        if (baselineUserMessages.has(node) || !voiceActive || !signalingConnected) return;
        const candidate = String(node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
        if (!candidate) return;
        if (isBackgroundOneShot() && utteranceFinishing) {
          updatePostReleaseDOMCandidate(node);
          return;
        }
        if (candidate === domPublished.get(node)) return;
        const previousTimer = domTimers.get(node);
        clearTimeout(previousTimer);
        pendingDOMTimers.delete(previousTimer);
        const timer = setTimeout(() => {
          pendingDOMTimers.delete(timer);
          if (!voiceActive || !signalingConnected) return;
          const stable = String(node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
          if (!stable || stable !== candidate || stable === domPublished.get(node)) return;
          domPublished.set(node, stable);
          send('protocol', `transcript source=dom stable_ms=1500 chars=${stable.length} text=[REDACTED]`);
          publishTranscript(stable, 'dom');
        }, 1500);
        domTimers.set(node, timer);
        pendingDOMTimers.add(timer);
      });
    };
    const userNodeFor = node => {
      const element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
      if (!element) return null;
      if (element.matches && element.matches('[data-message-author-role="user"]')) return element;
      return element.closest ? element.closest('[data-message-author-role="user"]') : null;
    };
    const changedUserNodes = records => {
      const nodes = new Set();
      records.forEach(record => {
        const owner = userNodeFor(record.target);
        if (owner) nodes.add(owner);
        record.addedNodes.forEach(added => {
          const addedOwner = userNodeFor(added);
          if (addedOwner) nodes.add(addedOwner);
          if (added && added.nodeType === Node.ELEMENT_NODE && added.querySelectorAll) {
            added.querySelectorAll('[data-message-author-role="user"]').forEach(node => nodes.add(node));
          }
        });
      });
      return nodes;
    };
    const startDOMObserver = () => {
      baselineCurrentUserMessages();
      domObserver = new MutationObserver(records => {
        const nodes = changedUserNodes(records);
        if (nodes.size) scanMessages(nodes);
      });
      domObserver.observe(document.documentElement, {childList: true, characterData: true, subtree: true});
    };
    document.readyState === 'loading'
      ? document.addEventListener('DOMContentLoaded', startDOMObserver, {once: true})
      : startDOMObserver();
  })();
  """#
}

/// Runs the official ChatGPT Voice surface without activating Squirrel or
/// stealing the user's insertion focus. WebKit still needs an attached window
/// for reliable media capture, so this uses a tiny non-key off-screen panel.
@MainActor
final class ChatGPTLiveBackgroundController: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
  static let shared = ChatGPTLiveBackgroundController()

  private enum SessionState: String {
    case idle
    case starting
    case ready
    case finalizing
    case closing
  }

  private struct StartRequest {
    let id: Int
    let targetApplication: NSRunningApplication?
    let settings: VoiceSettings
  }

  private var webView: WKWebView?
  private var panel: NSPanel?
  // Keep the captured application strongly until delivery. NSWorkspace may
  // return a short-lived wrapper; a weak reference was becoming nil before the
  // asynchronous final transcript arrived, causing copy-only fallback.
  private var targetApplication: NSRunningApplication?
  private var pendingStart = false
  private var queuedStart: StartRequest?
  private var queuedReleaseRequestID: Int?
  private var nextStartRequestID = 0
  private var sessionState: SessionState = .idle
  private var lastCommitted = ""
  private var signalingObserved = false
  private var liveSessionConnected = false
  private var pendingFinishUtterance = false
  private var lastEventLogged = ""
  private var lastEventLoggedAt = Date.distantPast
  private var voiceButtonWaitLoggedAt = Date.distantPast
  private var liveSettings = VoiceSettings()
  private var lifecycleGeneration = 0
  private var teardownGeneration = 0

  func start(targetApplication: NSRunningApplication?, settings: VoiceSettings) {
    if let targetApplication,
       targetApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
      self.targetApplication = targetApplication
    }
    nextStartRequestID += 1
    let request = StartRequest(id: nextStartRequestID,
                               targetApplication: self.targetApplication,
                               settings: settings)

    // A one-shot transcript session always mutes/finalizes its input tracks on
    // release. Reusing it was the 1.1.7.17 second-press deadlock: Swift still
    // saw a connected peer while the usable audio track had already gone away.
    guard settings.gptLiveMode == .conversation,
          sessionState == .ready,
          liveSessionConnected,
          webView != nil
    else {
      queuedStart = request
      if sessionState == .idle, webView == nil {
        startQueuedSessionIfPossible()
      } else {
        let reason = settings.gptLiveMode == .transcriptionOnly
          ? "fresh_transcription_turn" : "fresh_conversation_turn"
        beginTeardown(reason: reason)
      }
      return
    }

    // Conversation mode is the only mode allowed to resume a live connection.
    // If its sender track cannot be re-enabled, force a fresh, authenticated
    // WebView rather than leaving the user in a half-connected session.
    liveSettings = settings
    lastCommitted = ""
    ChatGPTLiveProtocolLog.shared.write("live.start result=reused_conversation_session target=\(self.targetApplication?.bundleIdentifier ?? "unknown") credentials=[WEBKIT_MANAGED]")
    applyLiveConfiguration()
    guard let resumingWebView = webView else {
      queuedStart = request
      beginTeardown(reason: "conversation_webview_missing")
      return
    }
    let resumeGeneration = lifecycleGeneration
    resumingWebView.evaluateJavaScript("window.__squirrelStartUtterance ? window.__squirrelStartUtterance() : -1") {
      [weak self] result, error in
      Task { @MainActor in
        guard let self,
              self.lifecycleGeneration == resumeGeneration,
              self.webView === resumingWebView,
              self.sessionState == .ready,
              self.liveSessionConnected
        else { return }
        let enabled = result as? Int ?? -1
        let resumed = error == nil && enabled > 0
        ChatGPTLiveProtocolLog.shared.write(
          "voice.utterance result=\(resumed ? "resumed" : "resume_failed") tracks=\(enabled)")
        guard resumed else {
          self.queuedStart = request
          self.beginTeardown(reason: "conversation_track_not_resumable")
          return
        }
        if settings.playSounds { NSSound(named: "Tink")?.play() }
      }
    }
  }

  private func startQueuedSessionIfPossible() {
    guard sessionState == .idle, let request = queuedStart else { return }
    queuedStart = nil
    lifecycleGeneration += 1
    liveSettings = request.settings
    targetApplication = request.targetApplication
    lastCommitted = ""
    signalingObserved = false
    liveSessionConnected = false
    pendingStart = true
    pendingFinishUtterance = queuedReleaseRequestID == request.id
    queuedReleaseRequestID = nil
    sessionState = .starting
    ChatGPTLiveProtocolLog.shared.write("live.start target=\(targetApplication?.bundleIdentifier ?? "unknown") credentials=[WEBKIT_MANAGED]")
    ensureWebView()
    applyLiveConfiguration()
    clickVoiceWhenReady()
  }

  private func ensureWebView() {
    guard webView == nil else { return }
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = ChatGPTBridge.sessionDataStore()
    cfg.userContentController.add(self, name: "squirrelLive")
    cfg.userContentController.addUserScript(WKUserScript(
      source: ChatGPTLoginView.liveConfigurationScript(settings: liveSettings, surface: "background"),
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true))
    cfg.userContentController.addUserScript(WKUserScript(source: ChatGPTLoginView.liveMonitorScript,
                                                          injectionTime: .atDocumentStart,
                                                          forMainFrameOnly: true))
    // WebKit suspends media work for fully off-screen/occluded views. Keep a
    // tiny view technically visible on screen, but transparent, non-key and
    // mouse-ignoring so it never steals the user's insertion focus.
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 32, height: 32), configuration: cfg)
    web.uiDelegate = self
    web.navigationDelegate = self
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let origin = NSPoint(x: visibleFrame.maxX - 34, y: visibleFrame.minY + 2)
    let win = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 32, height: 32)),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    win.collectionBehavior = [.transient, .ignoresCycle]
    win.hidesOnDeactivate = false
    win.ignoresMouseEvents = true
    win.alphaValue = 0.02
    win.level = .normal
    win.contentView = web
    win.orderFrontRegardless()
    webView = web
    panel = win
    web.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    applyLiveConfiguration()
    clickVoiceWhenReady()
  }

  private func applyLiveConfiguration() {
    webView?.evaluateJavaScript(
      ChatGPTLoginView.liveConfigurationScript(settings: liveSettings, surface: "background"))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ChatGPTLiveProtocolLog.shared.write("webcontent process=terminated")
    liveSessionConnected = false
    signalingObserved = false
    pendingFinishUtterance = false
    pendingStart = false
    self.webView = nil
    panel?.close()
    panel = nil
    sessionState = .idle
    DispatchQueue.main.async { [weak self] in self?.startQueuedSessionIfPossible() }
  }

  private func clickVoiceWhenReady() {
    let startGeneration = lifecycleGeneration
    guard pendingStart, sessionState == .starting, let webView else { return }
    let script = #"""
    (() => {
      const button = document.querySelector('button[data-testid="composer-speech-button"], button[aria-label="Start Voice"]');
      if (!button) return 'waiting';
      try { window.webkit.messageHandlers.squirrelLive.postMessage({kind:'protocol', value:`voice.click source=script trusted=false visible=${document.visibilityState} focus=${document.hasFocus()} activation=${navigator.userActivation && navigator.userActivation.isActive || false}`}); } catch (_) {}
      button.click();
      return 'clicked';
    })()
    """#
    webView.evaluateJavaScript(script) { [weak self] result, _ in
      Task { @MainActor in
        guard let self,
              self.lifecycleGeneration == startGeneration,
              self.pendingStart,
              self.sessionState == .starting
        else { return }
        if (result as? String) == "clicked" {
          self.pendingStart = false
          ChatGPTLiveProtocolLog.shared.write("voice.button result=clicked selector=[REDACTED_STABLE_SELECTOR]")
          DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self,
                  self.lifecycleGeneration == startGeneration,
                  self.sessionState == .starting,
                  !self.signalingObserved
            else { return }
            ChatGPTLiveProtocolLog.shared.write("voice.start result=timeout reason=no_realtime_signaling webview=visible_nonactivating")
            SquirrelApplicationDelegate.showMessage(
              msgText: NSLocalizedString("GPT Live needs a real click — click Voice in the window that opens", comment: "Voice"))
            // WebKit did not accept the synthetic DOM click as a user gesture.
            // Fall back to the visible, authenticated diagnostic surface so the
            // user can provide one trusted click; it retains the original target.
            NSApp.squirrelAppDelegate.openChatGPTLiveTest(targetApplication: self.targetApplication)
          }
        } else {
          let now = Date()
          if now.timeIntervalSince(self.voiceButtonWaitLoggedAt) >= 2 {
            self.voiceButtonWaitLoggedAt = now
            ChatGPTLiveProtocolLog.shared.write("voice.button result=waiting reason=selector_not_ready")
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.clickVoiceWhenReady() }
        }
      }
    }
  }

  func finishUtterance() {
    if sessionState == .closing, queuedStart != nil {
      queuedReleaseRequestID = queuedStart?.id
      ChatGPTLiveProtocolLog.shared.write("voice.utterance result=deferred reason=waiting_for_teardown")
      return
    }
    guard sessionState == .starting || sessionState == .ready else {
      ChatGPTLiveProtocolLog.shared.write("voice.utterance result=ignored reason=state_\(sessionState.rawValue)")
      return
    }
    pendingFinishUtterance = true
    finishUtteranceWhenReady()
  }

  func shutdown(reason: String) {
    // Explicit user/settings shutdown must not revive a queued hotkey turn.
    queuedStart = nil
    queuedReleaseRequestID = nil
    beginTeardown(reason: reason)
  }

  /// Close the private ChatGPT Voice surface and then force-detach its WebView.
  /// The delayed detach is intentional: some Web versions do not expose a
  /// usable End Voice control, so the native lifetime boundary is the fallback
  /// that guarantees a fresh session and releases WebKit microphone resources.
  private func beginTeardown(reason: String) {
    guard sessionState != .closing else { return }
    lifecycleGeneration += 1
    teardownGeneration += 1
    let teardownID = teardownGeneration
    let closingWebView = webView
    pendingStart = false
    pendingFinishUtterance = false
    liveSessionConnected = false
    signalingObserved = false
    sessionState = .closing
    let safeReason = reason.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_",
                                                  options: .regularExpression)
    ChatGPTLiveProtocolLog.shared.write("voice.teardown phase=begin reason=\(safeReason)")
    closingWebView?.evaluateJavaScript(
      "window.__squirrelShutdown ? window.__squirrelShutdown('\(safeReason)') : false")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak closingWebView] in
      guard let self,
            self.teardownGeneration == teardownID,
            self.sessionState == .closing
      else { return }
      closingWebView?.stopLoading()
      closingWebView?.navigationDelegate = nil
      closingWebView?.uiDelegate = nil
      closingWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "squirrelLive")
      if let closingWebView {
        if self.webView === closingWebView { self.webView = nil }
      } else {
        self.webView = nil
      }
      self.panel?.orderOut(nil)
      self.panel?.close()
      self.panel = nil
      self.sessionState = .idle
      ChatGPTLiveProtocolLog.shared.write("voice.teardown result=force_detached reason=\(safeReason)")
      DispatchQueue.main.async { [weak self] in self?.startQueuedSessionIfPossible() }
    }
  }

  private func finishUtteranceWhenReady() {
    guard pendingFinishUtterance else { return }
    guard liveSessionConnected else {
      if sessionState == .starting {
        ChatGPTLiveProtocolLog.shared.write("voice.utterance result=deferred reason=session_not_ready")
      } else {
        pendingFinishUtterance = false
        ChatGPTLiveProtocolLog.shared.write("voice.utterance result=cancelled reason=session_not_ready")
      }
      return
    }
    guard sessionState == .ready, let webView else {
      pendingFinishUtterance = false
      ChatGPTLiveProtocolLog.shared.write("voice.utterance result=cancelled reason=state_\(sessionState.rawValue)")
      return
    }
    let isOneShot = liveSettings.gptLiveMode == .transcriptionOnly
    if isOneShot { sessionState = .finalizing }
    let finishGeneration = lifecycleGeneration
    let finishingWebView = webView
    webView.evaluateJavaScript("window.__squirrelFinishUtterance ? window.__squirrelFinishUtterance() : -1") {
      [weak self] result, error in
      Task { @MainActor in
        guard let self,
              self.lifecycleGeneration == finishGeneration,
              self.webView === finishingWebView,
              self.pendingFinishUtterance,
              self.sessionState == (isOneShot ? .finalizing : .ready)
        else { return }
        let muted = result as? Int ?? -1
        if error == nil, muted > 0 {
          self.pendingFinishUtterance = false
          ChatGPTLiveProtocolLog.shared.write("voice.utterance result=muted_waiting_for_final tracks=\(muted)")
        } else {
          self.pendingFinishUtterance = false
          ChatGPTLiveProtocolLog.shared.write(
            "voice.utterance result=failed reason=\(error == nil ? "no_live_audio_track" : "script_error") action=teardown")
          self.beginTeardown(reason: error == nil ? "no_live_audio_track" : "finish_script_error")
          return
        }
        guard isOneShot else { return }
        let finalizationGeneration = self.lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
          guard let self,
                self.lifecycleGeneration == finalizationGeneration,
                self.sessionState == .finalizing
          else { return }
          ChatGPTLiveProtocolLog.shared.write("voice.finalization result=timeout action=teardown")
          self.beginTeardown(reason: "final_transcript_timeout")
        }
      }
    }
  }

  @available(macOS 12.0, *)
  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    let trustedVoiceOrigin = origin.host == "chatgpt.com" || origin.host.hasSuffix(".chatgpt.com")
    decisionHandler(trustedVoiceOrigin && type == .microphone ? .grant : .deny)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "squirrelLive",
          message.frameInfo.isMainFrame,
          ChatGPTLoginView.Coordinator.isTrustedChatGPTHost(message.frameInfo.securityOrigin.host),
          let payload = message.body as? [String: Any],
          let kind = payload["kind"] as? String else { return }
    let rawValue = payload["value"] as? String ?? ""
    let value = kind == "transcript" ? rawValue : String(rawValue.prefix(500))
    if kind == "protocol" {
      ChatGPTLiveProtocolLog.shared.writePageProtocol(value)
      return
    }
    if kind == "session" {
      if value == "active" {
        guard sessionState != .closing else {
          ChatGPTLiveProtocolLog.shared.write("ui.session value=active result=ignored state=closing")
          return
        }
        liveSessionConnected = true
        signalingObserved = true
        if sessionState == .starting {
          sessionState = .ready
        }
        if pendingFinishUtterance, sessionState == .ready {
          pendingFinishUtterance = false
          ChatGPTLiveProtocolLog.shared.write("voice.utterance result=cancelled reason=released_before_ready")
          SquirrelApplicationDelegate.showMessage(
            msgText: NSLocalizedString("GPT Live was not ready — hold the key until the ready sound, then speak", comment: "Voice"))
          beginTeardown(reason: "released_before_ready")
        } else if sessionState == .ready {
          if liveSettings.playSounds { NSSound(named: "Tink")?.play() }
          ChatGPTLiveProtocolLog.shared.write("ui.session value=active ready_for_speech=true")
        } else {
          ChatGPTLiveProtocolLog.shared.write("ui.session value=active state=\(sessionState.rawValue)")
        }
        return
      }
      if value == "inactive" {
        liveSessionConnected = false
        ChatGPTLiveProtocolLog.shared.write("ui.session value=inactive")
        return
      }
      if value == "closed" {
        liveSessionConnected = false
        signalingObserved = false
        pendingStart = false
        ChatGPTLiveProtocolLog.shared.write("ui.session value=closed")
        beginTeardown(reason: "web_session_closed")
      }
      return
    }
    if kind == "signaling" || kind == "peer" || kind == "channel" || kind == "event" {
      let messageGeneration = lifecycleGeneration
      if kind == "signaling",
         value.range(of: "^HTTP [0-9]{3} connected$", options: .regularExpression) != nil {
        signalingObserved = true
      }
      if kind == "peer" {
        if value == "connected" { signalingObserved = true }
      }
      if kind == "channel" {
        if value.hasSuffix(": open") { signalingObserved = true }
      }
      if kind == "event" {
        let now = Date()
        guard value != lastEventLogged || now.timeIntervalSince(lastEventLoggedAt) >= 30 else { return }
        lastEventLogged = value
        lastEventLoggedAt = now
      }
      ChatGPTLiveProtocolLog.shared.writePageState(kind: kind, value: value)
      let transportFailureReason: String?
      if kind == "signaling", value.hasSuffix(" failed") {
        transportFailureReason = "signaling_failed"
      } else if kind == "peer", value == "failed" || value == "closed" {
        transportFailureReason = "peer_\(value)"
      } else if kind == "channel", value == "data: error" {
        transportFailureReason = "datachannel_error"
      } else {
        transportFailureReason = nil
      }
      if let transportFailureReason {
        teardownTransportFailure(reason: transportFailureReason,
                                 generation: messageGeneration)
      }
      return
    }
    guard kind == "transcript" else { return }
    let transcript = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty, transcript != lastCommitted else { return }
    if liveSettings.gptLiveMode == .transcriptionOnly {
      guard sessionState == .finalizing else {
        ChatGPTLiveProtocolLog.shared.write("transcript result=ignored reason=state_\(sessionState.rawValue)")
        return
      }
      lastCommitted = transcript
      VoiceInputController.deliverLiveTranscript(transcript,
                                                 to: targetApplication,
                                                 settings: liveSettings)
    } else {
      ChatGPTLiveProtocolLog.shared.write("delivery result=skipped reason=conversation_mode chars=\(transcript.count)")
    }
  }

  private func teardownTransportFailure(reason: String, generation: Int) {
    guard lifecycleGeneration == generation,
          sessionState == .starting || sessionState == .ready || sessionState == .finalizing
    else { return }
    ChatGPTLiveProtocolLog.shared.write(
      "voice.transport result=failed reason=\(reason) action=teardown")
    beginTeardown(reason: reason)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url,
          url.scheme == "https",
          let host = url.host,
          ChatGPTLoginView.Coordinator.isTrustedChatGPTHost(host)
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }
}

struct ChatGPTLiveTestContainer: View {
  var done: () -> Void
  @StateObject private var monitor: ChatGPTLiveMonitor

  private var canStartVoice: Bool {
    // The diagnostic surface must not stack synthetic clicks on an existing
    // Voice session. Initial/closed/error are intentionally restartable.
    !monitor.voiceStartInFlight &&
      ["Not open", "data: closed", "data: error"].contains(monitor.dataChannel)
  }

  init(targetApplication: NSRunningApplication?, done: @escaping () -> Void) {
    let state = ChatGPTLiveMonitor()
    state.insertionTarget = targetApplication
    ChatGPTLiveProtocolLog.shared.write("surface=web_test opened target=\(targetApplication?.bundleIdentifier ?? "unknown") credentials=[WEBKIT_MANAGED]")
    _monitor = StateObject(wrappedValue: state)
    self.done = done
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(NSLocalizedString("GPT Live web test", comment: "Voice settings")).font(.headline)
          Text("Signaling: \(monitor.signaling)").font(.caption).textSelection(.enabled)
          Text("Peer: \(monitor.peerConnection) · Data: \(monitor.dataChannel)").font(.caption).textSelection(.enabled)
          if !monitor.lastEvent.isEmpty {
            Text("Event: \(monitor.lastEvent)").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
          }
          if !monitor.lastTranscript.isEmpty {
            Text("Transcript: \(monitor.lastTranscript)").font(.caption).textSelection(.enabled)
          }
        }
        Spacer()
        Button {
          monitor.startVoiceRequest += 1
        } label: {
          Label(NSLocalizedString("Start Voice", comment: "Voice settings"), systemImage: "waveform.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canStartVoice)
        Toggle(NSLocalizedString("Auto-insert final transcript", comment: "Voice settings"),
               isOn: $monitor.autoInsert)
          .toggleStyle(.checkbox)
        Button(NSLocalizedString("Done", comment: "Voice settings")) { done() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(8)
      ChatGPTLoginView(liveMonitor: monitor)
    }
    .frame(minWidth: 960, minHeight: 720)
  }
}

struct ChatGPTLoginContainer: View {
  var done: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(NSLocalizedString("Sign in to ChatGPT, then click Done.", comment: "Voice settings"))
          .foregroundColor(.secondary)
        Spacer()
        Button(NSLocalizedString("Done", comment: "Voice settings")) { done() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(8)
      ChatGPTLoginView()
    }
    .frame(minWidth: 800, minHeight: 600)
  }
}

// swiftlint:enable file_length type_body_length cyclomatic_complexity
