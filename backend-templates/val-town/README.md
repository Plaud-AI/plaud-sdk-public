# Val Town Template

The simplest possible Plaud token broker. **No CLI, no install, no GitHub push** — just paste in a browser and you have a live URL.

## Deploy in 30 Seconds

1. Open https://val.town/new and create a new HTTP val (TypeScript).
2. Copy the entire contents of [`index.ts`](./index.ts) and paste into the editor.
3. In the right sidebar, click **Environment Variables** and add three:
   - `PLAUD_CLIENT_ID` — from Plaud Developer Console
   - `PLAUD_SECRET_KEY` — from Plaud Developer Console
   - `MY_APP_SHARED_SECRET` — generate with `openssl rand -hex 32`
4. Click **Save**. Your URL appears at the top of the editor (something like `https://username-plaud-broker.web.val.run`).

That's it. Your endpoint is `<your-val-url>/issue-token`.

## Test It

```bash
curl -X POST https://your-username-plaud-broker.web.val.run/issue-token \
  -H "Content-Type: application/json" \
  -H "X-App-Secret: <MY_APP_SHARED_SECRET>" \
  -d '{"user_id":"test_user_001"}'
```

Expected response:
```json
{
  "plaud_token": "eyJhbGciOi...",
  "expires_in": 86400
}
```

## Configure the iOS Template App

Open `plaud-template-app/ios/PartnerConfig.local.xcconfig` and set:

```
BACKEND_TOKEN_ENDPOINT = https://your-username-plaud-broker.web.val.run/issue-token
MY_APP_SHARED_SECRET = <same value you set in Val Town>
```

Run `xcodegen generate`, build, and the app will fetch tokens from your Val Town broker.

## Why Val Town

| Pro | Con |
|---|---|
| Zero install — works in any browser | Vendor-specific (no easy port to other platforms — but the code is small) |
| Free tier: 100k requests/day | Paid plan needed for very high traffic |
| Logs and metrics built into the editor | Less of a "production grade" feel than Vercel/Cloudflare |
| Edits live, no redeploy | Public URL — keep `MY_APP_SHARED_SECRET` rotated |

For "ship a real app" use cases, prefer [`vercel/`](../vercel/) or [`cloudflare-worker/`](../cloudflare-worker/). Val Town shines for quick experiments, hackathons, internal tools, and learning the SDK without setup overhead.

## Limits and Caveats

- **Cold-start instances may not share cache** — the in-memory `partnerToken` cache resets when Val Town spins up a new instance. Each cold start = one extra `/oauth/partner/access-token` call. At normal traffic this is negligible.
- **Public URL by default** — anyone who knows the URL can hit it. The `X-App-Secret` header is your only gate. Rotate it if leaked.
- **No custom domain on free tier** — you'll have a `*.web.val.run` URL. For custom domain, upgrade to Val Town Pro.

## Region

Default: `https://platform-us.plaud.ai/developer/api`. Edit `PLAUD_BASE` near the top of [`index.ts`](./index.ts) for EU / JP / SG.
