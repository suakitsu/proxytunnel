# Security

ProxyTunnel is currently an alpha project intended for trusted local development.

- The example backend listens on `127.0.0.1` and allows only `127.0.0.0/8`.
- Do not expose ports 9190, 9191, Mihomo controller ports or subscription endpoints to the public Internet.
- Never report a vulnerability by attaching real credentials, subscriptions or node snapshots to a public issue.
- Rotate any credential that may have appeared in a log, screenshot or earlier internal package.
- The Cloudflare Worker admin UI accepts only the EdgeTunnel `ADMIN` secret. Cloudflare Global API Keys and API Tokens are deliberately rejected and are not read from KV.
- Worker login/admin HTML is bundled from `cloudflare/worker/admin-ui.js`; production requests do not load executable management UI from a third-party origin.
- `cloudflare/scripts/build-worker.mjs` is fail-closed: an incompatible upstream update must be reviewed before a new Worker bundle can be produced.

The current same-origin and confirmation-header checks are safety rails, not full authentication. Public deployment is unsupported until administrator authentication, CSRF protection and rate limiting are implemented.
