import AppKit
import SwiftUI
import WebKit

/// A store's own login page in a sheet, closed as soon as the page the login
/// ends on hands over its code.
///
/// The page keeps no cookies past the sheet: the store's client holds the
/// sign-in, so the web session has nothing left to do.
struct StoreSignInSheet: View {
    let store: GameStore
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StoreLoginWebView(store: store, onCode: onCode)
            Divider()
            HStack {
                Text("Sign in to \(store.displayName). The sheet closes by itself once you are in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 720)
    }
}

private struct StoreLoginWebView: NSViewRepresentable {
    let store: GameStore
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onCode: onCode)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Names itself as Safari does, which is the browser the login pages
        // are written for.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: store == .epic ? Legendary.loginURL : GOG.loginURL))
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: GameStore
        let onCode: (String) -> Void
        private var delivered = false

        init(store: GameStore, onCode: @escaping (String) -> Void) {
            self.store = store
            self.onCode = onCode
        }

        /// GOG's login ends on a page whose address holds the code; that
        /// page is never loaded.
        func webView(
            _: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void,
        ) {
            if store == .gog, let url = action.request.url, let code = GOG.authorizationCode(in: url) {
                decisionHandler(.cancel)
                deliver(code)
                return
            }
            decisionHandler(.allow)
        }

        /// Epic's login ends on a JSON page whose text holds the code.
        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            guard store == .epic, let url = webView.url, Legendary.isRedirectPage(url) else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] value, _ in
                guard let text = value as? String, let code = Legendary.authorizationCode(inPage: text) else { return }
                MainActor.assumeIsolated { self?.deliver(code) }
            }
        }

        private func deliver(_ code: String) {
            guard !delivered else { return }
            delivered = true
            onCode(code)
        }
    }
}
