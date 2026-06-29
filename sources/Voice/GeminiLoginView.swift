//
//  GeminiLoginView.swift
//  Squirrel
//
//  Embedded Gemini login (SPEC §14.5): a visible WKWebView backed by the same
//  in-memory WKWebsiteDataStore as GeminiWebBridge, so signing in to your
//  Google account here immediately authenticates the bridge — no google.com
//  cookies.json export needed. The session is snapshotted to the self-managed
//  store on window close (SPEC §4.8). Mirrors ChatGPTLoginView.
//

import SwiftUI
import WebKit

struct GeminiLoginView: NSViewRepresentable {
  func makeNSView(context: Context) -> WKWebView {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = GeminiWebBridge.sessionDataStore()
    let webView = WKWebView(frame: .zero, configuration: cfg)
    webView.load(URLRequest(url: URL(string: "https://gemini.google.com/app")!))
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct GeminiLoginContainer: View {
  var done: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(NSLocalizedString("Sign in to your Google account at gemini.google.com, then click Done.", comment: "Voice settings"))
          .foregroundColor(.secondary)
        Spacer()
        Button(NSLocalizedString("Done", comment: "Voice settings")) { done() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(8)
      GeminiLoginView()
    }
    .frame(minWidth: 800, minHeight: 600)
  }
}
