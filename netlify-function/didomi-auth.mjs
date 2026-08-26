// netlify/functions/didomi-auth.mjs
//
// Computes the Didomi cross-device authentication digest server-side,
// so the org secret NEVER ships in the mobile app or web page.
//
// Deploy: place this file at netlify/functions/didomi-auth.mjs in the site
// repo, and set two environment variables in the Netlify UI:
//   DIDOMI_SECRET_ID     e.g. "nyp-crossdevice-XXXX"  (the secret's ID in Didomi)
//   DIDOMI_SECRET_VALUE  the secret value registered with Didomi
//
// Request:  POST { "email": "user@example.com" }
// Response: { id, algorithm, secretID, digest, expiration }
//
// The organization user ID is a SHA-256 hash of the lowercased email, so no
// raw PII is sent to Didomi. The digest is HMAC-SHA256(id, secret), base64.

import crypto from "node:crypto";

export default async (request) => {
  const headers = {
    "Content-Type": "application/json",
    // CORS: allow the mobile app (no origin) and your demo pages
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };

  if (request.method === "OPTIONS") {
    return new Response("", { status: 204, headers });
  }
  if (request.method !== "POST") {
    return Response.json({ error: "POST only" }, { status: 405, headers });
  }

  const secretID = process.env.DIDOMI_SECRET_ID;
  const secretValue = process.env.DIDOMI_SECRET_VALUE;
  if (!secretID || !secretValue) {
    return Response.json(
      { error: "Server not configured (missing DIDOMI_SECRET_ID / DIDOMI_SECRET_VALUE)" },
      { status: 500, headers }
    );
  }

  let email;
  try {
    ({ email } = await request.json());
  } catch {
    return Response.json({ error: "Invalid JSON body" }, { status: 400, headers });
  }
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return Response.json({ error: "Valid 'email' is required" }, { status: 400, headers });
  }

  // NOTE: in a real deployment, authenticate this request (session token,
  // JWT, etc.) before issuing a digest. For the demo, the email is trusted.

  // Organization user ID: stable, per-user, no raw PII
  const id = crypto
    .createHash("sha256")
    .update(email.trim().toLowerCase())
    .digest("hex");

  // Didomi HMAC digest, per the docs:
  //   hmac-sha256: hmac('organization_user_id' + 'salt' + expiration, secret)
  // Salt and expiration are optional and NOT used here — the iOS SDK's
  // UserAuthWithHashParams (2.45) has no expiration parameter, and the
  // signed content must match exactly what the SDK sends. Hex-encoded.
  const digest = crypto
    .createHmac("sha256", secretValue)
    .update(id)
    .digest("hex");

  return Response.json(
    {
      id,
      algorithm: "hmac-sha256",
      secretID,
      digest,
      expiration: null,
    },
    { status: 200, headers }
  );
};

export const config = { path: "/api/didomi-auth" };
