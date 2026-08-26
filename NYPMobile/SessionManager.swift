//
//  SessionManager.swift
//  NYPMobile
//
//  Hybrid cross-device consent identity:
//
//  1. DEVICE LEVEL (default, no backend needed) — a Keychain-persisted UUID
//     is set as the organization user ID with an unauthenticated setUser.
//     Didomi's backend stores consent against it, so consent survives app
//     reinstalls. Follows the device, not the person.
//
//  2. USER LEVEL (email login) — the app asks the backend (Netlify Function
//     holding the org secret) for an HMAC digest and calls setUser with
//     authenticated params. Consent then follows the person across devices.
//     If the backend is unreachable, falls back to an unauthenticated
//     email-derived ID so the demo still works without deploying anything.
//
//  Logout returns to the device-level identity (not to "no identity").
//

import Foundation
import SwiftUI
import CryptoKit
import Didomi

@Observable
final class SessionManager {

    static let shared = SessionManager()

    // MARK: State
    var email: String? = UserDefaults.standard.string(forKey: "loggedInEmail")
    var orgUserId: String?
    var isAuthenticated = false     // true = server-signed digest in use
    var syncApplied = false
    var isLoggingIn = false
    var lastError: String?

    var identityLabel: String {
        if email != nil { return isAuthenticated ? "User (signed)" : "User (unsigned)" }
        return "Device"
    }

    // MARK: Config
    private let authEndpoint = URL(string: "https://nypcprabanner.netlify.app/api/didomi-auth")!

    struct AuthResponse: Decodable {
        let id: String
        let algorithm: String
        let secretID: String
        let digest: String
        let expiration: Double?
    }

    // MARK: Backend call — the only place a signed digest comes from
    private func fetchAuth(email: String) async throws -> AuthResponse {
        var request = URLRequest(url: authEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    private func makeUserParameters(
        _ auth: AuthResponse,
        containerController: UIViewController? = nil
    ) -> DidomiUserParameters {
        DidomiUserParameters(
            userAuth: UserAuthWithHashParams(
                id: auth.id,
                algorithm: auth.algorithm,
                secretID: auth.secretID,
                digest: auth.digest,
                salt: nil
            ),
            containerController: containerController
        )
    }

    private static func emailDerivedId(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash = SHA256.hash(data: Data(normalized.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Launch
    // Sets the identity on the SDK BEFORE initialize, so remote consent is
    // synced during startup and no stale notice is shown.
    func bootstrap() {
        if let savedEmail = email {
            Task {
                do {
                    let auth = try await fetchAuth(email: savedEmail)
                    self.orgUserId = auth.id
                    self.isAuthenticated = true
                    Didomi.shared.setUser(self.makeUserParameters(auth))
                    print("👤 setUser (pre-init, signed) for org user \(auth.id.prefix(12))…")
                } catch {
                    // Backend unreachable → unsigned email-derived identity
                    let id = Self.emailDerivedId(savedEmail)
                    self.orgUserId = id
                    self.isAuthenticated = false
                    Didomi.shared.setUser(id: id)
                    print("👤 setUser (pre-init, unsigned fallback) for org user \(id.prefix(12))…")
                }
                Self.initializeSDK()
            }
        } else {
            // Device-level identity: no backend, no login. Keychain UUID
            // survives reinstall, so consent does too (via Didomi sync).
            let deviceId = DeviceIdentity.id
            orgUserId = deviceId
            isAuthenticated = false
            Didomi.shared.setUser(id: deviceId)
            print("📱 setUser (pre-init, device-level): \(deviceId)")
            Self.initializeSDK()
        }
    }

    static func initializeSDK() {
        let parameters = DidomiInitializeParameters(
            apiKey: "8983bdb1-e1c7-4c63-abc3-c6e4d60ead3c",
            noticeID: "CEctn3xW"
        )
        Didomi.shared.initialize(parameters)

        Didomi.shared.onReady {
            print("✅ Didomi SDK is ready (NYP)")
            AppDelegate.dumpIABStrings("SDK ready")
            NotificationCenter.default.post(name: .didomiReady, object: nil)
        }
    }

    // MARK: Login / logout
    func login(email rawEmail: String) async {
        let trimmed = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoggingIn = true
        lastError = nil
        defer { isLoggingIn = false }

        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.rootViewController

        do {
            let auth = try await fetchAuth(email: trimmed)
            orgUserId = auth.id
            isAuthenticated = true
            // SDK already initialized → containerController lets the SDK
            // re-display the notice if the synced status is incomplete.
            Didomi.shared.setUser(makeUserParameters(auth, containerController: root))
            print("👤 setUser (post-init, signed) for org user \(auth.id.prefix(12))…")
        } catch {
            // No backend deployed / offline → unsigned email-derived identity
            let id = Self.emailDerivedId(trimmed)
            orgUserId = id
            isAuthenticated = false
            Didomi.shared.setUser(id: id)
            print("👤 setUser (post-init, unsigned fallback) for org user \(id.prefix(12))…")
        }

        email = trimmed
        UserDefaults.standard.set(trimmed, forKey: "loggedInEmail")
    }

    func logout() {
        Didomi.shared.clearUser()
        email = nil
        syncApplied = false
        UserDefaults.standard.removeObject(forKey: "loggedInEmail")

        // Return to the device-level identity rather than no identity
        let deviceId = DeviceIdentity.id
        orgUserId = deviceId
        isAuthenticated = false
        Didomi.shared.setUser(id: deviceId)
        print("👋 clearUser() → back to device-level identity: \(deviceId)")
    }
}
