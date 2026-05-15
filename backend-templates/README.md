# Plaud Backend Templates

Tiny token broker servers for the Plaud Embedded SDK. Pick a stack, set three environment variables, deploy. Your mobile app talks to the broker — never to Plaud directly with `client_id` / `secret_key`.

---

## Why You Need This

Your mobile app **must not contain** `PLAUD_CLIENT_ID` or `PLAUD_SECRET_KEY`. Anyone who installs the app can extract embedded strings, intercept HTTPS with a jailbroken device, or dump runtime memory. Once leaked, an attacker can issue tokens for every user, drain your transcription quota, and cost you real money.

A token broker is a **tiny** server (≈30 lines of code) that sits between your app and Plaud:

```
   ┌────────────┐    HTTPS       ┌──────────────┐    HTTPS       ┌──────────────┐
   │ Mobile App │ ─────────────▶ │ Token Broker │ ─────────────▶ │ Plaud API    │
   │            │ ◀───────────── │  (this dir)  │ ◀───────────── │              │
   └────────────┘  user_token    └──────────────┘ Basic Auth     └──────────────┘
                                  ^
                                  │ holds CLIENT_ID + SECRET_KEY
                                  │ (env vars, never in code)
```

The broker:
1. Accepts a request from your app (with your own shared secret — not Plaud's)
2. Exchanges `CLIENT_ID + SECRET_KEY` for a `partner_access_token`
3. Exchanges that for a `user_access_token` scoped to one user
4. Returns the `user_access_token` to your app

That's it. No business logic, no state, runs free on every major serverless platform.

---

## Pick a Template

Three templates, three audiences, no overlap. **If unsure → pick Vercel.** It's the best balance of zero-CLI deployment and production-ready hosting.

| Template | Best for | Setup time | Free tier | Has CLI option |
|---|---|---|---|---|
| [`val-town/`](./val-town/) | "I want to see it work in 30 seconds" | 30s | 100k req/day | No (browser only) |
| [`vercel/`](./vercel/) ⭐ | Shipping a real app, no terminal | 2 min | 100k req/month | Yes (`vercel deploy`) |
| [`cloudflare-worker/`](./cloudflare-worker/) | Global edge, max free tier | 2 min (button) / 5 min (CLI) | 100k req/day | Yes (`wrangler deploy`) |

Want Express / Lambda / FastAPI / Go / etc.? See [`val-town/index.ts`](./val-town/index.ts) — it's the simplest reference implementation; port from there. PRs welcome.

---

## Three Environment Variables (All Templates)

| Variable | Where to get it | Purpose |
|---|---|---|
| `PLAUD_CLIENT_ID` | Plaud Developer Console → your Embedded SDK Client | Identifies your partner account |
| `PLAUD_SECRET_KEY` | Same place, shown once at creation | Authenticates your partner account |
| `MY_APP_SHARED_SECRET` | **You generate** (`openssl rand -hex 32`) | Lets your broker reject random web traffic |

> **About `MY_APP_SHARED_SECRET`:** This *will* be extractable from your mobile app binary. It is a basic spam shield, not a real secret. The point is to make casual abuse hard. For real abuse-resistance, layer in App Attest (iOS) / Play Integrity (Android) — see [`docs/app-attest-integration.md`](../docs/app-attest-integration.md) (TODO).

---

## Universal Endpoint Contract

Every template implements the same one-route HTTP API. **Your mobile app code stays identical regardless of which backend you deploy.**

### `POST /issue-token`

**Request:**
```http
POST /issue-token
Content-Type: application/json
X-App-Secret: <MY_APP_SHARED_SECRET>

{ "user_id": "your-app-user-id-string" }
```

**Response (200):**
```json
{
  "plaud_token": "eyJhbGciOi...",
  "expires_in": 86400
}
```

**Response (401):** `{"detail":"unauthorized"}` — wrong or missing `X-App-Secret`.
**Response (400):** `{"detail":"user_id is required (string, 1-256 chars)"}` — bad `user_id`.
**Response (502):** `{"detail":"plaud upstream failed", "upstream_status":..., "upstream_body":"..."}` — Plaud returned an error (bad credentials, region mismatch, quota).

---

## iOS Client Code (Swift, 8 lines)

Drop this anywhere in your iOS app. Pass the result into `PlaudDeviceAgent.shared.initSDK(userAccessToken:, customDomain:)`.

```swift
struct IssueTokenResp: Decodable { let plaud_token: String; let expires_in: Int }

func fetchPlaudToken(userId: String) async throws -> String {
    var req = URLRequest(url: URL(string: "https://your-broker.example.com/issue-token")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(APP_SHARED_SECRET, forHTTPHeaderField: "X-App-Secret")
    req.httpBody = try JSONEncoder().encode(["user_id": userId])
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONDecoder().decode(IssueTokenResp.self, from: data).plaud_token
}
```

For the full integration with auto-refresh and 401 retry, see [`plaud-template-app/ios/PlaudTemplateApp/Managers/BackendTokenProvider.swift`](../plaud-template-app/ios/PlaudTemplateApp/Managers/BackendTokenProvider.swift).

---

## Region Note

All templates default to `https://platform-us.plaud.ai/developer/api`. If your Plaud account is on a different region, change the constant near the top of each template. See [`docs/multi-region-architecture.md`](../docs/multi-region-architecture.md) for region URLs (US deployed, JP deployed, EU/SG planned).

---

## Security Checklist (Read Before Deploying)

- [ ] `PLAUD_CLIENT_ID` and `PLAUD_SECRET_KEY` are stored **only** as platform secrets (Cloudflare/Vercel/Val Town env vars), **never** in source files.
- [ ] `MY_APP_SHARED_SECRET` is a 256-bit random value (`openssl rand -hex 32`), stored the same way.
- [ ] Your broker URL is HTTPS-only (all listed platforms enforce this by default).
- [ ] If a secret is ever leaked (committed, mentioned in chat, screenshotted), rotate immediately in Plaud Console.
- [ ] Consider per-IP rate limiting in front of the broker if you expect public-facing distribution.

---

## Local Testing

Each template has a "test locally" section in its own README. The contract is the same — start the broker, then `curl` to verify:

```bash
curl -X POST http://localhost:PORT/issue-token \
  -H "Content-Type: application/json" \
  -H "X-App-Secret: $MY_APP_SHARED_SECRET" \
  -d '{"user_id":"test_user_001"}'
```

Expected: 200 with a `plaud_token` field. Decode the JWT at [jwt.io](https://jwt.io) and confirm `user_id` matches.

---

## Contributing a Template

Want to add Bun, Deno Deploy, Rust Axum, Spring Boot, .NET, etc.? PRs welcome. Constraints:

- Single-file or near-single-file business logic
- ≤ 80 LOC of code
- Same `POST /issue-token` contract
- README modeled on `vercel/README.md`
- `.env.example` (never `.env`) committed
