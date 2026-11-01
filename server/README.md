# Awwbum scoring server

A small Cloudflare Worker that lets Awwbum Plus subscribers have their photos scored by Claude without
their own Anthropic API key. The app sends a shrunken photo plus its App Store receipt; the server checks
the subscription with Apple's signature, checks the monthly limit, asks Claude, and returns Claude's answer.

Photos and Claude's replies are never saved or logged. The logs only show which address was called, the
result code, how long it took, and a short scrambled code for the subscription.

## One-time setup (about 15 minutes)

You need a computer with Node.js installed (the same one used for this repo is fine) and a Terminal
window opened in this `server` folder.

1. **Create a free Cloudflare account** at https://dash.cloudflare.com/sign-up and confirm your email.
   The free plan covers this server (100,000 requests a day).

2. **Install the tools** (once):

   ```
   npm install
   ```

3. **Log in from the Terminal.** This opens a browser window; click "Allow".

   ```
   npx wrangler login
   ```

4. **Create the storage for monthly photo counts:**

   ```
   npx wrangler kv namespace create awwbum-QUOTA
   ```

   It prints a few lines that include `id = "…"` (a long string of letters and numbers). Open
   `wrangler.toml` in a text editor and replace `PASTE_YOUR_KV_NAMESPACE_ID_HERE` with that id
   (keep the quote marks). Save the file.

5. **Add your Anthropic API key as a secret** (it is stored encrypted at Cloudflare, never in a file):

   ```
   npx wrangler secret put ANTHROPIC_API_KEY
   ```

   Paste the key from https://console.anthropic.com/settings/keys when asked and press Return.
   Wrangler may ask to create the Worker first; answer yes.

6. **Publish the server:**

   ```
   npx wrangler deploy
   ```

   At the end it prints the server's address, something like
   `https://awwbum-server.<your-name>.workers.dev`. **That address is what goes into the app.**
   You can also find it later in the Cloudflare dashboard under **Workers & Pages → awwbum-server**
   (shown at the top as the "workers.dev" route).

To check it's live, open `https://awwbum-server.<your-name>.workers.dev/v1/quota` in a browser: you
should see `{"error":{"type":"not_subscribed",…}}`. That's correct; the browser has no subscription.

## Changing settings later

Settings live in `wrangler.toml` under `[vars]`. After editing, run `npx wrangler deploy` again.

| Setting | What it does |
| --- | --- |
| `BUNDLE_ID` | The app's bundle id (`com.grantoster.awwlist`). |
| `PRODUCT_IDS` | Subscription products that unlock scoring, comma separated. |
| `MONTHLY_LIMIT` | Photos per subscription per calendar month (UTC). Default 5000. |
| `ALLOWED_ENVIRONMENTS` | `Production,Sandbox` lets TestFlight/sandbox purchases work. Keep both: Apple's App Review buys subscriptions in Sandbox, so `Production` alone would fail review. |

To replace the API key, run step 5 again. To see live log lines, run `npx wrangler tail` (it shows
request details for as long as it runs; nothing is kept afterwards).

## For developers

```
npm test            # unit tests (vitest)
npm run typecheck   # tsc --noEmit
npm run dev         # local server at http://localhost:8787 (uses local, fake storage)
npm run deploy      # same as npx wrangler deploy
```

### API

All requests to scoring and quota carry the header `X-Awwbum-Transaction: <Transaction.jwsRepresentation>`
(the StoreKit 2 signed transaction for the active Awwbum Plus subscription).

`POST /v1/score` with body `{"image": "<base64 JPEG, ≤768 px long side>", "model": "claude-haiku-5-5"}`
(`model` optional: `claude-haiku-5-5` (default), `claude-sonnet-5-5`, `claude-opus-5-5`). On success,
returns Anthropic's Messages API response unchanged with status 200.

`GET /v1/quota` returns `{"used": 12, "limit": 5000, "resets": "2026-12-01T00:00:00.000Z"}`.

Errors are `{"error": {"type": "...", "message": "..."}}`:

| Status | type | When |
| --- | --- | --- |
| 400 | `invalid_request_error` | Body isn't JSON, unknown model, image isn't base64 JPEG, or Claude rejected the image |
| 401 | `not_subscribed` | Missing, invalid, untrusted, expired, revoked, wrong app/product/environment transaction |
| 404 | `not_found_error` | Any other path or method |
| 413 | `request_too_large` | Image over 1,500,000 base64 characters (or body over that plus 1 KB) |
| 429 | `quota_exceeded` | Monthly limit reached; `Retry-After` = seconds until the 1st of next month (UTC) |
| 429 | (Anthropic's own body) | Anthropic rate limit, passed through with its `Retry-After` |
| 5xx | `overloaded_error` | Anthropic 5xx/529 (same status), Anthropic unreachable or server misconfigured (502), server error (500) |

Only successful (200) scores count toward the monthly limit.
