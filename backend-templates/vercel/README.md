# Vercel Edge Function Template ⭐ Recommended

Plaud token broker as a Vercel Edge Function. Recommended for most users — **deploy with one click, no terminal**.

## Deploy in 2 Minutes (Zero CLI)

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2FPlaud-AI%2Fplaud-sdk-public&root-directory=backend-templates%2Fvercel&env=PLAUD_CLIENT_ID,PLAUD_SECRET_KEY,MY_APP_SHARED_SECRET&envDescription=Three%20env%20vars%20%E2%80%94%20see%20backend-templates%2FREADME.md%20for%20what%20each%20does&envLink=https%3A%2F%2Fgithub.com%2FPlaud-AI%2Fplaud-sdk-public%2Fblob%2Fmain%2Fbackend-templates%2FREADME.md)

The button:
1. Asks you to log into Vercel (GitHub auth, instant)
2. Forks `plaud-sdk-public` to your GitHub
3. Prompts for the three environment variables
4. Deploys to a `*.vercel.app` URL

Endpoint: `https://your-broker.vercel.app/api/issue-token`

## Or Deploy via CLI

```bash
npm i -g vercel
cd backend-templates/vercel
cp .env.example .env.local    # edit with your real values
vercel deploy --prod
```

You'll be prompted to log in and link a project. Subsequent deploys are just `vercel deploy --prod`.

## Test It

```bash
curl -X POST https://your-broker.vercel.app/api/issue-token \
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
BACKEND_TOKEN_ENDPOINT = https://your-broker.vercel.app/api/issue-token
MY_APP_SHARED_SECRET = <same value you set in Vercel>
```

Run `xcodegen generate`, build, and the app will fetch tokens from your Vercel broker.

## Local Development

```bash
cd backend-templates/vercel
cp .env.example .env.local    # fill in real values
npx vercel dev
```

`vercel dev` runs the function locally on `http://localhost:3000`. Test with:

```bash
curl -X POST http://localhost:3000/api/issue-token \
  -H "Content-Type: application/json" \
  -H "X-App-Secret: $MY_APP_SHARED_SECRET" \
  -d '{"user_id":"test_user_001"}'
```

## Custom Domain

Vercel dashboard → Settings → Domains → Add. Free on the Hobby tier (you bring the domain).

## Region

Default: `https://platform-us.plaud.ai/developer/api`. Edit `PLAUD_BASE` near the top of [`api/issue-token.js`](./api/issue-token.js) for EU / JP / SG.

## Why Vercel

| Pro | Con |
|---|---|
| 1-click deploy from a button | Free tier capped at 100k req/month (hit it → upgrade) |
| Free SSL + global CDN | Serverless cold start ~50-100ms |
| Familiar to most JS devs | Vendor lock-in (but the code is small and portable) |
| Logs, metrics, env vars all in one dashboard | Edge runtime is a Node subset (no `fs`, `child_process` etc., but we don't need them) |
