# Cloudflare Worker Template

Plaud token broker as a Cloudflare Worker. Best for **global edge latency** (0ms cold start) and **largest free tier** (100k req/day).

## Deploy in 2 Minutes (Zero CLI)

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/Plaud-AI/plaud-sdk-public/tree/main/backend-templates/cloudflare-worker)

The button:
1. Asks you to log into Cloudflare (or sign up — email-only)
2. Forks `plaud-sdk-public` to your GitHub
3. Connects the fork to a new Worker project
4. Prompts for the three environment variables on first deploy

## Or Deploy via CLI

```bash
npm i -g wrangler
cd backend-templates/cloudflare-worker
wrangler login                              # opens browser for OAuth
wrangler secret put PLAUD_CLIENT_ID         # paste value when prompted
wrangler secret put PLAUD_SECRET_KEY        # paste value when prompted
wrangler secret put MY_APP_SHARED_SECRET    # paste value when prompted
wrangler deploy
```

You'll get a URL like `https://plaud-token-broker.YOUR-USERNAME.workers.dev`. Endpoint: `<that-url>/issue-token`.

## Test It

```bash
curl -X POST https://plaud-token-broker.YOU.workers.dev/issue-token \
  -H "Content-Type: application/json" \
  -H "X-App-Secret: <MY_APP_SHARED_SECRET>" \
  -d '{"user_id":"test_user_001"}'
```

Expected:
```json
{ "plaud_token": "eyJhbGciOi...", "expires_in": 86400 }
```

Decode the JWT at [jwt.io](https://jwt.io) — `user_id` should equal `test_user_001`.

## Configure the iOS Template App

Open `plaud-template-app/ios/PartnerConfig.local.xcconfig` and set:

```
BACKEND_TOKEN_ENDPOINT = https://plaud-token-broker.YOU.workers.dev/issue-token
MY_APP_SHARED_SECRET = <same value you set via wrangler secret put>
```

Run `xcodegen generate`, build, and the app will fetch tokens from your Worker.

## Local Development

```bash
cd backend-templates/cloudflare-worker
cp .dev.vars.example .dev.vars        # fill in real values
wrangler dev                          # starts http://localhost:8787
```

Test with:
```bash
curl -X POST http://localhost:8787/issue-token \
  -H "Content-Type: application/json" \
  -H "X-App-Secret: $MY_APP_SHARED_SECRET" \
  -d '{"user_id":"test_user_001"}'
```

## Custom Domain

Cloudflare dashboard → Workers & Pages → your worker → Triggers → Custom Domains. Free if your domain is on Cloudflare DNS.

## Region

Default: `https://platform-us.plaud.ai/developer/api`. Edit `PLAUD_BASE` near the top of [`src/index.js`](./src/index.js) for EU / JP / SG.

## Why Cloudflare Workers

| Pro | Con |
|---|---|
| Free tier: 100k requests/**day** (largest of the three) | Wrangler CLI for power features (button covers basics) |
| Zero cold start (V8 isolates, not containers) | Edge runtime is a Web API subset (no Node `fs`, `child_process`) |
| Global: 300+ cities | Slightly less mainstream than Vercel for indie devs |
| `wrangler tail` for live log streaming | KV / Durable Objects cost extra (we don't need them) |
