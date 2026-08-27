//
//  ContentView.swift
//  NYPMobile
//
//  Loads a Didomi-tagged page in a WKWebView and injects the app's consent
//  state so the web SDK shares it (no duplicate banner). Includes an
//  email login that links the session to an organization user ID for
//  cross-device consent, via a server-side digest.
//

import SwiftUI
import WebKit
import Didomi

// MARK: - Didomi setupUI host
// Per https://developers.didomi.io/cmp/mobile-sdk/ios/setup, setupUI must be
// called in viewDidLoad of the app's entry-point UIViewController. In SwiftUI,
// we wrap a UIViewController with UIViewControllerRepresentable and keep it
// in the view hierarchy.
struct DidomiSetupView: UIViewControllerRepresentable {

    class DidomiViewController: UIViewController {

        override func viewDidLoad() {
            super.viewDidLoad()
            Didomi.shared.setupUI(containerController: self)
        }

    }

    func makeUIViewController(context: Context) -> DidomiViewController {
        DidomiViewController()
    }

    func updateUIViewController(_ uiViewController: DidomiViewController, context: Context) {}

}

// MARK: - Shared WKWebView store
@Observable
final class WebViewStore {

    let webView = WKWebView()
    let pageURL = URL(string: "https://newyorkpostwebnotice.netlify.app")!

    // (Re)loads the page with the CURRENT consent state injected at document
    // start. Called on first load and again after a cross-device sync so the
    // page always reflects the latest consent.
    func loadWithConsent() {
        Didomi.shared.onReady {
            let js = Didomi.shared.getJavaScriptForWebView()
            let controller = self.webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(
                WKUserScript(
                    source: js,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            self.webView.load(URLRequest(url: self.pageURL))
        }
    }

    func showPrivacyWidget() {
        // Diagnostic: is the web SDK actually loaded in the page?
        webView.evaluateJavaScript("typeof window.Didomi") { result, _ in
            print("ℹ️ typeof window.Didomi in page:", result ?? "unknown")
        }

        // Same as the web implementation's
        // <button onclick="Didomi.widgets.show()">Your Privacy Choices</button>
        // queued so it is safe even before the web SDK finishes loading.
        let js = """
        window.didomiOnReady = window.didomiOnReady || [];
        window.didomiOnReady.push(function (Didomi) {
            try {
                Didomi.widgets.show();
            } catch (e) {
                console.log("widgets.show failed, falling back:", e);
                Didomi.preferences.show();
            }
        });
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("❌ Didomi.widgets.show() failed:", error)
            } else {
                print("✅ Didomi.widgets.show() queued in WebView")
            }
        }
    }

}

struct WebView: UIViewRepresentable {

    let store: WebViewStore

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        store.webView.navigationDelegate = context.coordinator
        store.loadWithConsent()
        return store.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {

            // Belt-and-braces: also evaluate after load.
            Didomi.shared.onReady {

                let js = Didomi.shared.getJavaScriptForWebView()

                webView.evaluateJavaScript(js) { _, error in

                    if let error = error {
                        print("❌ Failed to inject Didomi JS")
                        print(error)
                    } else {
                        print("✅ Didomi JS injected into WebView")
                    }

                }

            }

        }

    }

}

// MARK: - Presentation helper
// Returns the TOP-MOST visible view controller — a guaranteed-valid
// presenter. The root VC alone is not enough: if anything is already
// presented (notice, sheet), presenting from the root fails silently.
func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .keyWindow?.rootViewController

    var top = root
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

// MARK: - Main view
struct ContentView: View {

    @State private var isReady = false
    @State private var store = WebViewStore()
    @State private var session = SessionManager.shared
    @State private var emailInput = ""

    var body: some View {

        VStack(spacing: 0) {

            VStack(alignment: .leading, spacing: 8) {

                Text("New York Post — Didomi Demo")
                    .font(.headline)

                // MARK: Login / account row
                if let email = session.email {

                    HStack {

                        VStack(alignment: .leading, spacing: 2) {

                            Text(email)
                                .font(.caption)

                            if let orgUserId = session.orgUserId {
                                Text("\(session.identityLabel): \(orgUserId.prefix(16))…")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                        }

                        Spacer()

                        HStack(spacing: 4) {

                            Image(systemName: session.syncApplied
                                  ? "checkmark.icloud.fill"
                                  : "icloud.slash")
                                .foregroundStyle(session.syncApplied ? .green : .secondary)

                            Text(session.syncApplied ? "Synced" : "Local")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                        }

                        Button("Log Out") {
                            session.logout()
                            store.loadWithConsent()
                        }
                        .font(.caption)

                    }

                } else {

                    VStack(alignment: .leading, spacing: 4) {

                        HStack {

                            TextField("email@example.com", text: $emailInput)
                                .font(.caption)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button(session.isLoggingIn ? "…" : "Log In") {
                                Task {
                                    await session.login(email: emailInput)
                                }
                            }
                            .font(.caption)
                            .disabled(session.isLoggingIn || emailInput.isEmpty)

                        }

                        // Device-level identity active while logged out
                        if let orgUserId = session.orgUserId {
                            Text("\(session.identityLabel) identity: \(orgUserId.prefix(22))…")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                    }

                }

                if let error = session.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                // MARK: Privacy actions
                // NOTE: this NYP config manages consent through the PMP
                // privacy widget, which is a web component — there is no
                // native preferences surface to show (showPreferences has
                // nothing to render for a widget-based CPRA setup). All
                // visible consent UI lives in the webview; the native SDK
                // still stores/syncs consent and writes the IAB strings.
                HStack {

                    // Same as the web implementation:
                    // <button onclick="Didomi.widgets.show()">Your Privacy Choices</button>
                    Button("Your Privacy Choices") {
                        store.showPrivacyWidget()
                    }
                    .font(.caption)

                    Spacer()

                }

            }
            .padding()

            Divider()

            if isReady {

                WebView(store: store)
                    .ignoresSafeArea(edges: .bottom)

            } else {

                Spacer()

                ProgressView("Initializing Didomi SDK...")

                Spacer()

            }

        }
        .background(DidomiSetupView()) // hosts setupUI — renders the native notice on launch
        .onReceive(NotificationCenter.default.publisher(for: .didomiReady)) { _ in
            isReady = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .didomiSyncReady)) { _ in
            // Remote consent was applied — reload the page with fresh state
            store.loadWithConsent()
        }

    }

}

#Preview {
    ContentView()
}
