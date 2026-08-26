# Cross-Device Consent — Setup Guide

Real cross-device consent with a login and per-user organization user IDs
(no hardcoded user, no secret in the app).

## Identity modes (hybrid)

The app runs a two-tier identity model. **Didomi's backend is the consent
database** in both modes — no customer database is required for consent storage.

| Mode | Org user ID | Backend needed | What it gives you |
|---|---|---|---|
| **Device level** (default, logged out) | UUID generated once, persisted in the **Keychain** (survives reinstall) | None | Consent survives app reinstalls via Didomi sync; follows the *device* |
| **User level** (email login) | `sha256(email)`, digest signed server-side | Netlify Function (holds the secret) | Consent follows the *person* across app, web, and devices |

Logging out returns to the device-level identity (not "no identity").
If the Netlify Function is unreachable, login falls back to an **unsigned**
email-derived ID so the demo still works with zero deployment — the header
badge shows "User (unsigned)" vs "User (signed)" so you always know which
path is active. Unsigned IDs work only if the org does not enforce digest
signatures; production should always use the signed path.

## How it works

```
User logs in with email (app or web)
  └─ client POSTs { email } to /api/didomi-auth  (Netlify Function)
       └─ function (holds the org secret in env vars):
            id     = sha256(lowercased email)        ← stable, no raw PII
            digest = hmac-sha256(id + expiration, secret), hex
            → returns { id, algorithm, secretID, digest, expiration }
  └─ client calls setUser with those values
       └─ Didomi links this device/browser to the org user ID
            and syncs consent through the Didomi backend
```

The same email on any device/site produces the same organization user ID,
so consent follows the user. The secret lives only in Netlify env vars.

## 1. Deploy the Netlify Function

Copy `netlify-function/didomi-auth.mjs` into your site repo (the one deployed
to `nypcprabanner.netlify.app`) at:

```
netlify/functions/didomi-auth.mjs
```

In the Netlify UI → Site settings → Environment variables, add:

| Variable | Value |
|---|---|
| `DIDOMI_SECRET_ID` | the secret's ID registered with Didomi for the NYP org |
| `DIDOMI_SECRET_VALUE` | the secret value |

Deploy. The endpoint is `https://nypcprabanner.netlify.app/api/didomi-auth`.

Test it:

```bash
curl -X POST https://nypcprabanner.netlify.app/api/didomi-auth \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com"}'
# → {"id":"973dfe46...","algorithm":"hmac-sha256","secretID":"...","digest":"...","expiration":1754...}
```

> ⚠️ The demo function trusts the email it's given. In production, this
> endpoint must sit behind real authentication (session cookie / JWT) so a
> caller can only obtain a digest for their own identity.

## 2. iOS app (already wired)

- **`SessionManager.swift`** — owns the flow:
  - *Returning user* (saved email): fetches a fresh digest, calls
    `Didomi.shared.setUser(...)` **before** `initialize` → remote consent
    syncs during SDK startup.
  - *Fresh login*: SDK already initialized, so `setUser` is called with a
    `containerController` → the SDK syncs and re-shows the notice if the
    synced status doesn't cover this notice.
  - *Logout*: `Didomi.shared.clearUser()`.
- **`NYPMobileApp.swift`** — `onSyncReady` / `onSyncError` listeners update
  the UI ("Synced" badge) and reload the webview with fresh consent state.
- **UI** — email field in the header; the org user ID and sync status are
  shown once logged in.

## 3. Web side (to demo app ↔ web sync)

For consent to sync to the *website* on another device, the page must
identify the same user. On the banner page, after your web login (or a
simple email prompt for the demo), call the same endpoint and pass the
result to the web SDK **before the Didomi tag loads**:

```html
<script>
  async function didomiLogin(email) {
    const res = await fetch("/api/didomi-auth", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email })
    });
    const auth = await res.json();

    window.didomiConfig = window.didomiConfig || {};
    window.didomiConfig.user = {
      organizationUserId: auth.id,
      organizationUserIdAuthAlgorithm: auth.algorithm, // "hmac-sha256"
      organizationUserIdAuthSid: auth.secretID,
      organizationUserIdAuthDigest: auth.digest,
      organizationUserIdExp: auth.expiration
    };
    // then load (or reload the page with) the Didomi tag
  }
</script>
```

(Exact web-side property names: check
https://developers.didomi.io/cmp/web-sdk/share-consents-across-devices —
the pattern is the same: id + algorithm + secret ID + digest from the server.)

## 4. Demo script

1. On the **website** (desktop browser): log in as `alice@example.com`,
   make consent choices.
2. In the **app** (fresh install): log in as `alice@example.com` →
   `onSyncReady` fires with `statusApplied: true` → the native notice does
   NOT appear (consent came from the web session) → "Synced" badge is green.
3. Change preferences in the app (Native Preferences) → back on the website,
   reload → choices match.
4. Log out in the app → `clearUser()` → log in as `bob@example.com` →
   different org user, fresh consent → notice appears.

## Requirements checklist

- [ ] Cross-device sync enabled for the notice (`sync.enabled: true` in the
      notice config; sync frequency min 6h)
- [ ] Secret registered with Didomi for the NYP org (gives you the secret ID)
- [ ] `DIDOMI_SECRET_ID` / `DIDOMI_SECRET_VALUE` set in Netlify
- [ ] Function deployed and returning 200
- [ ] App + web page using the SAME API key (`8983bdb1-...`)

## Digest formula reference

Per Didomi docs (web SDK cross-device page):

- `hmac-sha256`: `hmac(organization_user_id + salt + expiration, secret)` —
  hex-encoded; salt and expiration are optional.
- This setup signs the **id only** (no salt, no expiration), because the iOS
  SDK's `UserAuthWithHashParams` (2.45) takes `(id:algorithm:secretID:digest:salt:)`
  with no expiration parameter — and the signed content must match exactly
  what the SDK sends alongside the digest.

If Didomi rejects the digest (sync error mentioning signature), verify the
secret value and that the function signs exactly `id`.
