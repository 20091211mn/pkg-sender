# Support (customer service) setup

Users write to you from the app (Settings > Help and support). You answer from the admin app (Support tab).
Everything is stored as issues in a **private** GitHub repository; a free Cloudflare Worker sits between the app
and GitHub so that no token is ever inside the app.

## 1. Private support repository
```bash
gh repo create pkg-sender-support --private --confirm
```

## 2. Token for the relay
GitHub > Settings > Developer settings > Fine-grained tokens > Generate:
- Repository access: **Only select repositories** > `pkg-sender-support`
- Permissions: **Issues = Read and write**

## 3. The relay (Cloudflare, free)
1. Create a Cloudflare account > Workers & Pages > **Create** > **Create Worker** > Deploy > **Edit code**.
2. Replace the code with `support/worker.js` and deploy.
3. Worker > Settings > Variables and Secrets:
   - `SUPPORT_REPO` (text): `owner/pkg-sender-support`
   - `GITHUB_TOKEN` (secret): the token from step 2
4. Copy the Worker address (`https://....workers.dev`).

Test it (Termux):
```bash
curl -s -X POST https://YOUR-WORKER.workers.dev/ticket -H 'content-type: application/json' -d '{"message":"test message"}'
```
It must answer `{"id":1,"key":"..."}` and a new issue appears in the support repository.

## 4. Tell the app where it is
```bash
gh variable set SUPPORT_URL --body "https://YOUR-WORKER.workers.dev" --repo OWNER/REPO
```
Then build again (the address is compiled into the app). Until it is set, the app shows "support is not enabled".

## 5. Admin app
Support tab > the repository name defaults to `<repo>-support`; change it with the pencil icon if needed.
The admin token needs access to that private repository (a classic token with `repo` has it).
