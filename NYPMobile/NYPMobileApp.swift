//
//  NYPMobileApp.swift
//  NYPMobile
//
//  New York Post — Didomi consent demo with cross-device consent.
//  SDK initialization is driven by SessionManager so a logged-in user is
//  set on the SDK BEFORE initialize (remote consent syncs during startup).
//

import SwiftUI
import Didomi
import OSLog

class AppDelegate: NSObject, UIApplicationDelegate {

    let eventListener = EventListener()

    // Dumps the IAB strings Didomi writes to UserDefaults — this is what
    // native ad SDKs (GAM, AdMob, Prebid Mobile) read on their own.
    static func dumpIABStrings(_ context: String) {
        let keys = [
            "IABTCF_TCString",        // TCF consent string (GDPR)
            "IABTCF_gdprApplies",
            "IABTCF_PurposeConsents",
            "IABGPP_HDR_GppString",   // GPP string (US state laws)
            "IABGPP_GppSID",          // GPP section IDs in effect
            "IABUSPrivacy_String"     // legacy CCPA / US Privacy string
        ]
        print("──── IAB strings in UserDefaults (\(context)) ────")
        for key in keys {
            let value = UserDefaults.standard.object(forKey: key)
            print("\(key) = \(value.map { "\($0)" } ?? "nil")")
        }
        print("──────────────────────────────────────────────")
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        Didomi.shared.setLogLevel(minLevel: OSLogType.debug.rawValue)

        // Cross-device sync events
        eventListener.onSyncReady = { event in
            print("✅ Cross-device sync ready")
            print("Organization User ID: \(event.organizationUserId)")
            print("Remote status applied: \(event.statusApplied)")

            Task { @MainActor in
                SessionManager.shared.syncApplied = event.statusApplied
                NotificationCenter.default.post(name: .didomiSyncReady, object: nil)
            }
        }

        eventListener.onSyncError = { event, error in
            print("❌ Cross-device sync error")
            print("Event: \(event)")
            print("Error: \(error ?? "Unknown error")")

            Task { @MainActor in
                SessionManager.shared.syncApplied = false
                SessionManager.shared.lastError = "Sync error: \(error ?? "unknown")"
            }
        }

        // Re-dump the IAB strings every time the user changes consent
        eventListener.onConsentChangedWithObject = { _ in
            AppDelegate.dumpIABStrings("consent changed")
        }

        Didomi.shared.addEventListener(listener: eventListener)

        // Sets user (if logged in) then initializes the SDK
        SessionManager.shared.bootstrap()

        return true
    }
}

extension Notification.Name {
    static let didomiReady = Notification.Name("didomiReady")
    static let didomiSyncReady = Notification.Name("didomiSyncReady")
}

@main
struct NYPMobileApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
