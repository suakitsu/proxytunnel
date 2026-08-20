# Cloudflare EdgeTunnel integration

## Upstream used by this project

The deployment article supplied during the extraction process uses [`cmliu/edgetunnel`](https://github.com/cmliu/edgetunnel). This repository pins that upstream as a Git submodule. A deterministic local build step generates the deployable Worker instead of editing the submodule or deploying `_worker.js` directly.

Pinned commit:

```text
92fc6cc4a4cbfdf536394bc9b0397e5948b039f8
```

The third-party article describes a manual Pages upload flow. Treat it as an onboarding aid, not as the source of truth for Cloudflare APIs or security requirements. ProxyTunnel uses the current Wrangler Worker workflow so users do not manually copy a KV namespace ID.

## Minimum user input

Only one project value is required for the normal Cloudflare path:

- `ADMIN`: an EdgeTunnel administrator password, entered through a secure prompt.

Everything else is either automatic or optional:

- Wrangler performs browser authentication when the local machine has not signed in.
- `cloudflare/wrangler.jsonc` declares a draft KV binding named `KV`; current Wrangler versions can automatically provision and bind the namespace during deployment.
- EdgeTunnel derives its UUID and subscription token from `ADMIN` unless an advanced override is intentionally configured.
- `START.cmd` authenticates to the deployed Worker with `ADMIN`, reads the runtime `HOST` and `UUID`, and derives the Clash subscription automatically. The password is never written to disk.
- `cloudflare\DEPLOY.cmd` records the resulting `workers.dev` URL under ignored local runtime state when Wrangler prints it. Deployments created elsewhere ask for their site URL once.
- The Worker name has a safe project default.
- A custom domain is optional; the generated `workers.dev` hostname is enough to start.

## Local validation with Wrangler

Install dependencies and create a local-only admin value:

```powershell
Set-Location .\cloudflare
npm ci
Copy-Item .\.dev.vars.example .\.dev.vars
npm run cf:dry-run
npm run cf:dev
```

`npm run cf:dev` serves HTTPS locally. EdgeTunnel redirects HTTP to HTTPS, so using Wrangler's HTTP default would otherwise create a local redirect loop.

Wrangler runs `cloudflare/scripts/build-worker.mjs`, then bundles `cloudflare/worker/index.js`. The build step reads the pinned `third_party/edgetunnel/_worker.js`, validates unique patch anchors, isolates request-scoped dial settings with `AsyncLocalStorage`, disables Cloudflare account-credential storage/lookups, and serves the repository's own `/login` and `/admin` pages. The generated file is ignored because it is reproducible. If an upstream update no longer matches the audited anchors, the build fails instead of deploying an unreviewed fallback.

The checked-in configuration declares the `KV` binding but contains no account, route, namespace ID, or secret value. The launcher requires `ADMIN`; local development reads it from ignored `cloudflare/.dev.vars`. Local development uses local KV storage by default.

The bundled admin page never accepts a Cloudflare Global API Key or API Token. Use the Cloudflare Dashboard or Wrangler for account usage and configuration so high-privilege credentials cannot enter Worker URLs, logs, or KV.

## Confirmed production deployment

Double-click `cloudflare\DEPLOY.cmd`. The launcher:

1. describes every production-side effect;
2. exits unless the user types `DEPLOY`;
3. asks once for `ADMIN` using a masked prompt;
4. stores the value only in a temporary secrets file outside the repository;
5. performs a Wrangler dry-run;
6. signs in through the browser when required;
7. deploys with strict conflict checking and automatic KV provisioning;
8. clears the in-memory BSTR and removes the validated temporary directory.

Account-specific binding IDs are written to ignored `cloudflare/wrangler.production.jsonc`, not the reusable template. The launcher does not delete Workers, KV data, routes, domains, or unrelated resources.

Still required before a stable public release:

- a dedicated staging environment and tested rollback;
- release signing and checksums;
- production administrator authentication for the local management console.

Official references:

- [Wrangler automatic resource provisioning](https://developers.cloudflare.com/workers/wrangler/configuration/#automatic-provisioning)
- [Workers environment variables and local secrets](https://developers.cloudflare.com/workers/configuration/environment-variables/)
- [Workers secrets](https://developers.cloudflare.com/workers/configuration/secrets/)
- [Workers KV with Wrangler](https://developers.cloudflare.com/kv/get-started/)

Do not treat “free”, “permanent”, “unlimited” or “always stable” claims in third-party tutorials as availability guarantees.
