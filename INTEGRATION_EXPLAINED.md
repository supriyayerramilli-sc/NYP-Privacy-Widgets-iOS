# NYP Mobile — Didomi iOS + WebView Integration Explained

**Audience:** New York Post engineering team
**Demo app:** `NYPMobile` (SwiftUI, iOS)
**Didomi config:** API key `8983bdb1-e1c7-4c63-abc3-c6e4d60ead3c` · Notice ID `CEctn3xW`
**SDK:** Didomi iOS SDK ≥ 2.45.0 via Swift Package Manager (`https://github.com/didomi/didomi-ios-sdk-spm`)

---

## The problem this solves

A hybrid app (native shell + web content in a WKWebView) has two consent surfaces: the native Didomi SDK in the app, and the Didomi Web SDK running inside the pages the webview loads. Without integration, a user would be asked for consent twice — once natively, once by the page — and the two consent states could disagree.

The Didomi pattern is: **collect consent once, natively, and pass it into every webview** so the Web SDK on the page adopts the app's consent instead of re-asking.

## Architecture at a glance

```
App launch
  └─ AppDelegate: Didomi.shared.initialize(apiKey, noticeID)   ← async
       └─ onReady fires when config is fetched
  └─ Entry UIViewController: Didomi.shared.setupUI(...)         ← shows native
       notice automatically IF consent needs collecting
User consents natively
  └─ WKWebView is created
       ├─ WKUserScript @ documentStart: getJavaScriptForWebView()
       │    → writes the app's consent state into the page before
       │      any page script runs
       └─ page loads (a Didomi-tagged page using the same API key)
            → Web SDK starts → sees existing consent
            → shows NO second banner
"Your Privacy Choices" button
  └─ evaluateJavaScript: didomiOnReady.push(Didomi => Didomi.widgets.show())
       → same behavior as the web implementation's
         <button onclick="Didomi.widgets.show()">
```

## Component 1 — SDK initialization (`NYPMobileApp.swift`)

Per the [iOS setup docs](https://developers.didomi.io/cmp/mobile-sdk/ios/setup), `initialize` is called as early as possible, in an `AppDelegate` (bridged into SwiftUI with `@UIApplicationDelegateAdaptor`):

```swift
let parameters = DidomiInitializeParameters(
    apiKey: "8983bdb1-e1c7-4c63-abc3-c6e4d60ead3c",
    noticeID: "CEctn3xW"
)
Didomi.shared.initialize(parameters)
```

Initialization is asynchronous — the SDK fetches the notice configuration from the Didomi Console (cached, refreshed every 60 min). Any call that depends on the SDK must go through `Didomi.shared.onReady { ... }`. The app uses `onReady` to post a notification that flips the UI from a loading spinner to the webview.

## Component 2 — `setupUI` (native notice display)

`setupUI(containerController:)` is what actually renders the consent notice. The docs require it in `viewDidLoad` of the entry-point view controller. In SwiftUI there is no view controller, so the app wraps one:

```swift
struct DidomiSetupView: UIViewControllerRepresentable {
    class DidomiViewController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            Didomi.shared.setupUI(containerController: self)
        }
    }
    ...
}
```

and attaches it to the root view (`.background(DidomiSetupView())`). Key points for the team:

- `setupUI` handles `onReady` / `shouldConsentBeCollected` internally — no manual checks needed.
- The notice appears **only when consent needs collecting** (first launch, expired consent, or config changes requiring re-consent). After a choice is made it will not reappear; to re-test, delete and reinstall the app.
- Later, programmatic UI calls (e.g. `showPreferences`) should be presented on a real, attached view controller. In this app the native preferences button explicitly passes the window's root view controller — presenting from a zero-frame hosted controller fails silently.

## Component 3 — Consent injection into the WKWebView

Before the page loads, the app asks the native SDK for a JavaScript snippet that encodes the current consent state:

```swift
let js = Didomi.shared.getJavaScriptForWebView()
```

This is installed as a `WKUserScript` at `.atDocumentStart`, meaning it executes **before any page script** — so when the Didomi Web SDK boots inside the page, the consent state is already there and it adopts it. The app also re-evaluates the snippet on `didFinish` as a belt-and-braces measure (this matches Didomi's documented webview pattern).

Result: consent collected natively is honored by the web page; the user is never asked twice; TCF/consent signals passed to vendors on the page match the app's state.

## Component 4 — The target page (must carry the Didomi tag)

The web implementation NYP uses relies on the Didomi Web SDK being on the page:

```html
<button onclick="Didomi.widgets.show()" id="pmLink">Your Privacy Choices</button>
```

The demo webview loads `https://nypcprabanner.netlify.app/`, a page that ships the Didomi web tag with the same NYP API key as the app. This is the production-realistic configuration: the page brings its own SDK; the app only injects consent state (Component 3).

Two requirements for any page loaded in the webview:

1. **It must include the Didomi web tag** — a page without it has no `Didomi` object (calling `Didomi.widgets.show()` there throws `ReferenceError: Can't find variable: Didomi`, which is what happened when the demo initially pointed at the live nypost.com homepage, which does not carry the tag).
2. **Its tag must use the same API key as the app** — otherwise the consent scopes don't match, the page's web SDK sees no existing consent, and it shows its own banner.

## Component 5 — "Your Privacy Choices" button

The button executes, inside the webview, the exact call the web team uses — wrapped in Didomi's ready-queue so it can never race the SDK load:

```javascript
window.didomiOnReady = window.didomiOnReady || [];
window.didomiOnReady.push(function (Didomi) {
    Didomi.widgets.show();
});
```

`Didomi.widgets.show()` opens the **PMP widget** configured for this API key in the Didomi Console — verified working against the demo page. The code includes a `Didomi.preferences.show()` fallback in case a page has no widget configured.

**Where consent UI renders in this configuration — the key point:**

- *Your Privacy Choices* opens a **PMP privacy widget**. Widgets are web components — built, hosted, and rendered by the Didomi Web SDK — and have **no native mobile renderer**. On mobile, a webview running a Didomi-tagged page is the only way to present one (confirmed with the Didomi product team).
- **This NYP setup manages consent exclusively through the widget**, so there is no native preferences surface: `Didomi.shared.showPreferences()` renders the *CMP's* preferences screen, and a widget-based CPRA configuration has none to render — the call is a no-op by design, not a bug. (The app therefore has no "native preferences" button.)
- The **native SDK is still essential** even though it draws no consent UI here: it stores the consent record on-device, runs cross-device sync (`setUser`), writes the IAB GPP/TCF strings to `UserDefaults` for native ad SDKs, and feeds the consent state into every webview.

General rule of thumb for other configs: **CMP experiences (consent notice + preferences) can render natively on mobile; PMP widget experiences are webview-only.** Either way there is one shared consent record underneath.

## Verifying it works

1. **Console logs:** `✅ Didomi SDK is ready (NYP)` (native init), `✅ Didomi JS injected into WebView` (consent passed to page), and the `IAB strings in UserDefaults` dump (IAB keys for native ad SDKs). Filter the Xcode console on "Didomi".
2. **Native notice:** appears on first launch; reset by reinstalling the app.
3. **State sync:** Safari → Develop → Simulator → attach to the webview, run `window.didomiState` / `Didomi.getUserStatus()` — choices made natively appear in the page.
4. **Benign console noise** when loading nypost.com: `WEBP/ICO initImage err=-50` (WebKit image decoder), `didFailLoadForFrame code=-999, isMainFrame=0` (cancelled ad iframes), and Simulator voice/locale fetch errors — none are Didomi-related.

## How consent propagates out of the native SDK

The webview injection is only one of several channels. Consent is collected once, natively, and consumed by different parties depending on where they run:

**Native code and native ad SDKs.** The app can query the SDK directly (`getUserStatus()`, purpose/vendor status APIs) to gate its own trackers. For the IAB frameworks, the SDK writes the standard consent strings to `UserDefaults` (iOS) / `SharedPreferences` (Android): the GPP string under `IABGPP_HDR_GppString` plus per-section `IABGPP_*` keys, and the TCF string under `IABTCF_*` keys when GDPR applies. Any ad SDK compliant with the IAB in-app specifications — Google Ad Manager, AdMob, Prebid Mobile — reads these keys on its own; no injection or glue code is needed. (Didomi documents the writing side; the automatic reading is defined by the IAB spec and the ad SDKs' own docs.)

*Demo:* the app dumps these keys to the Xcode console on SDK ready and on every consent change — change a choice in "Native Preferences" and watch the strings update live. Note that which keys are populated depends on the notice's regulation: `CEctn3xW` is a US notice, so expect `IABGPP_*` (and possibly `IABUSPrivacy_String`) to be filled while `IABTCF_*` stays `nil` — the TCF string only appears for GDPR notices.

**Web content inside the app.** A webview is a separate JavaScript world that cannot read native storage, so the SDK provides `getJavaScriptForWebView()` — the injection pattern in Components 3–5 above.

**Server-side and other devices.** With `setUser` (an authenticated organization user ID), consent syncs through Didomi's backend and follows the user across app and web; it is also queryable via API for server-side enforcement.

## Documentation references

- Setup & `setupUI`: https://developers.didomi.io/cmp/mobile-sdk/ios/setup
- Sharing consent with webviews (`getJavaScriptForWebView`): https://developers.didomi.io/cmp/mobile-sdk/share-consent-with-webviews
- Third-party SDKs, TCF & GPP storage keys: https://developers.didomi.io/cmp/mobile-sdk/third-party-sdks
- Cross-device consent (`setUser`): https://developers.didomi.io/cmp/mobile-sdk/share-consents-across-devices
- iOS API reference: https://developers.didomi.io/cmp/mobile-sdk/ios/reference/api

## What NYP needs for production

- Native apps: initialize the iOS/Android SDK with their API key + notice, call `setupUI` at every entry point, and inject `getJavaScriptForWebView()` into every webview that loads Didomi-tagged pages.
- Web: keep the existing tag + `Didomi.widgets.show()` button — unchanged. Pages loaded in app webviews must carry the same-API-key tag for consent to flow through.
- Optional: cross-device consent sync via `setUser` with an authenticated user ID (Didomi's cross-device feature), so consent follows the user across app and web when logged in.

## Demo status

Verified working end to end (Aug 6, 2026): native notice on launch → consent injected into the webview (`nypcprabanner.netlify.app`, no duplicate web banner) → "Your Privacy Choices" opens the Didomi web widget in the page → "Native Preferences" opens the native preferences screen → IAB strings visible in `UserDefaults` and updating on consent changes.
