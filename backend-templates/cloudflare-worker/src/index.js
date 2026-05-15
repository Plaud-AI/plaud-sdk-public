/**
 * Plaud Token Broker — Cloudflare Worker
 *
 * One endpoint: POST /issue-token
 *   Header  X-App-Secret: <MY_APP_SHARED_SECRET>
 *   Body    { "user_id": "..." }
 *   Returns { "plaud_token": "...", "expires_in": 86400 }
 *
 * Holds CLIENT_ID + SECRET_KEY in env (Cloudflare secrets).
 * Mobile app never sees them; only ever sees the per-user token returned here.
 *
 * Region: change PLAUD_BASE if your account is on EU / JP / SG.
 */

const PLAUD_BASE = "https://platform-us.plaud.ai/developer/api";
const TOKEN_TTL_SECONDS = 86400;

// In-worker memo for the partner_access_token (24h, free).
// Workers may cycle between requests, so this is best-effort cache.
let partnerToken = null;
let partnerExpiresAt = 0;

async function getPartnerToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (partnerToken && now < partnerExpiresAt - 60) return partnerToken;

  const auth = btoa(`${env.PLAUD_CLIENT_ID}:${env.PLAUD_SECRET_KEY}`);
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

async function issueUserToken(env, userId, retried = false) {
  const partner = await getPartnerToken(env);
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
      return issueUserToken(env, userId, true);
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

export default {
  async fetch(request, env) {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/issue-token") {
      return jsonResponse({ detail: "not found" }, 404);
    }

    if (request.headers.get("X-App-Secret") !== env.MY_APP_SHARED_SECRET) {
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
      const result = await issueUserToken(env, userId);
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
  },
};
