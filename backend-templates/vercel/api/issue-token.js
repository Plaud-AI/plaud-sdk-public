/**
 * Plaud Token Broker — Vercel Edge Function
 *
 * File path = URL: this file is reachable at /api/issue-token after deploy.
 * No vercel.json needed; Vercel auto-detects edge functions in api/.
 *
 * Endpoint: POST <your-vercel-url>/api/issue-token
 *   Header  X-App-Secret: <MY_APP_SHARED_SECRET>
 *   Body    { "user_id": "..." }
 *   Returns { "plaud_token": "...", "expires_in": 86400 }
 *
 * Region: change PLAUD_BASE if your account is on EU / JP / SG.
 */

export const config = { runtime: "edge" };

const PLAUD_BASE = "https://platform-us.plaud.ai/developer/api";
const TOKEN_TTL_SECONDS = 86400;

// Per-instance memo for partner_access_token (24h, free).
// Edge instances may cycle between requests, so this is best-effort cache.
let partnerToken = null;
let partnerExpiresAt = 0;

async function getPartnerToken() {
  const now = Math.floor(Date.now() / 1000);
  if (partnerToken && now < partnerExpiresAt - 60) return partnerToken;

  const auth = btoa(`${process.env.PLAUD_CLIENT_ID}:${process.env.PLAUD_SECRET_KEY}`);
  const resp = await fetch(`${PLAUD_BASE}/oauth/partner/access-token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!resp.ok) throw new UpstreamError(resp.status, await resp.text());
  const json = await resp.json();
  partnerToken = json.access_token;
  partnerExpiresAt = now + (json.expires_in ?? 3600);
  return partnerToken;
}

async function issueUserToken(userId, retried = false) {
  const partner = await getPartnerToken();
  const resp = await fetch(`${PLAUD_BASE}/open/partner/users/access-token`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${partner}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ user_id: userId, expires_in: TOKEN_TTL_SECONDS }),
  });
  if (!resp.ok) {
    if (resp.status === 401 && !retried) {
      partnerToken = null;
      partnerExpiresAt = 0;
      return issueUserToken(userId, true);
    }
    throw new UpstreamError(resp.status, await resp.text());
  }
  return resp.json();
}

class UpstreamError extends Error {
  constructor(status, body) {
    super(`upstream ${status}`);
    this.status = status;
    this.body = body;
  }
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default async function handler(request) {
  if (request.method !== "POST") {
    return jsonResponse({ detail: "method not allowed" }, 405);
  }

  if (request.headers.get("X-App-Secret") !== process.env.MY_APP_SHARED_SECRET) {
    return jsonResponse({ detail: "unauthorized" }, 401);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ detail: "invalid json body" }, 400);
  }
  const userId = body?.user_id;
  if (typeof userId !== "string" || userId.length === 0 || userId.length > 256) {
    return jsonResponse({ detail: "user_id is required (string, 1-256 chars)" }, 400);
  }

  try {
    const result = await issueUserToken(userId);
    return jsonResponse({
      plaud_token: result.access_token,
      expires_in: result.expires_in ?? TOKEN_TTL_SECONDS,
    });
  } catch (err) {
    if (err instanceof UpstreamError) {
      return jsonResponse(
        { detail: "plaud upstream failed", upstream_status: err.status, upstream_body: err.body },
        502,
      );
    }
    return jsonResponse({ detail: "internal error", message: String(err) }, 500);
  }
}
