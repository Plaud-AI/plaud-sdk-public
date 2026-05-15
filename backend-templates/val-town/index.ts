/**
 * Plaud Token Broker — Val Town
 *
 * The simplest possible deployment: paste this entire file into a new Val at
 * https://val.town/new (HTTP handler type), set 3 env vars in the sidebar,
 * and you have a live URL. No CLI, no install, no GitHub push.
 *
 * Endpoint: POST <your-val-url>/issue-token
 *   Header  X-App-Secret: <MY_APP_SHARED_SECRET>
 *   Body    { "user_id": "..." }
 *   Returns { "plaud_token": "...", "expires_in": 86400 }
 *
 * Region: change PLAUD_BASE if your account is on EU / JP / SG.
 */

const PLAUD_BASE = "https://platform-us.plaud.ai/developer/api";
const TOKEN_TTL_SECONDS = 86400;

// In-memory cache for partner_access_token (per Val instance, best-effort).
let partnerToken: string | null = null;
let partnerExpiresAt = 0;

async function getPartnerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (partnerToken && now < partnerExpiresAt - 60) return partnerToken;

  const clientId = Deno.env.get("PLAUD_CLIENT_ID");
  const secretKey = Deno.env.get("PLAUD_SECRET_KEY");
  if (!clientId || !secretKey) {
    throw new Error("Missing PLAUD_CLIENT_ID or PLAUD_SECRET_KEY env var");
  }
  const auth = btoa(`${clientId}:${secretKey}`);

  const resp = await fetch(`${PLAUD_BASE}/oauth/partner/access-token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!resp.ok) {
    throw new UpstreamError(resp.status, await resp.text());
  }
  const json = await resp.json();
  partnerToken = json.access_token;
  partnerExpiresAt = now + (json.expires_in ?? 3600);
  return partnerToken!;
}

async function issueUserToken(userId: string, retried = false): Promise<{ access_token: string; expires_in?: number }> {
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
      // partner_access_token expired between cache check and use; bust and retry once.
      partnerToken = null;
      partnerExpiresAt = 0;
      return issueUserToken(userId, true);
    }
    throw new UpstreamError(resp.status, await resp.text());
  }
  return resp.json();
}

class UpstreamError extends Error {
  constructor(public status: number, public body: string) {
    super(`upstream ${status}`);
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default async function (request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "POST" || !url.pathname.endsWith("/issue-token")) {
    return jsonResponse({ detail: "not found" }, 404);
  }

  if (request.headers.get("X-App-Secret") !== Deno.env.get("MY_APP_SHARED_SECRET")) {
    return jsonResponse({ detail: "unauthorized" }, 401);
  }

  let body: { user_id?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ detail: "invalid json body" }, 400);
  }
  const userId = body.user_id;
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
