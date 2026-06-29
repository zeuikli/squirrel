//
//  ChatGPTLoginView.swift
//  Squirrel
//
//  Embedded ChatGPT login (SPEC §14.5): a visible WKWebView backed by the
//  same in-memory WKWebsiteDataStore as ChatGPTBridge, so signing in here
//  immediately authenticates the bridge — no cookies.json export needed. The
//  session is snapshotted to the self-managed store on window close (SPEC §4.8).
//

import SwiftUI
import WebKit

struct ChatGPTLoginView: NSViewRepresentable {
  func makeNSView(context: Context) -> WKWebView {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = ChatGPTBridge.sessionDataStore()
    let webView = WKWebView(frame: .zero, configuration: cfg)
    webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
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
