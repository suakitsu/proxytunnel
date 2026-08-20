# ProxyTunnel

> A self-hosted control plane for EdgeTunnel and Mihomo proxy pools.

[简体中文](README.md) · [English](README_EN.md)

> [!WARNING]
> ProxyTunnel is currently `0.1.0-alpha.1`. It builds, tests, and serves the local control plane, but it is not ready for direct Internet exposure or stable production use. Use it only with networks, Cloudflare accounts, and nodes you are authorized to manage, and follow applicable laws and provider terms.

## Overview

ProxyTunnel combines an EdgeTunnel data plane on Cloudflare, a Mihomo proxy runtime, and a local operations console into an observable and manageable proxy-pool system.

It does not reimplement the EdgeTunnel protocol. Instead, it adds the operational layer that is usually missing: candidate discovery, verified egress inspection, country filtering, custom pools, isolated ports, Clash/v2rayN exports, persistent background jobs, reusable pool profiles, health telemetry, and operator action history.

The current code was extracted from a real internal deployment and converted into a standalone project. Production configuration, credentials, logs, node snapshots, company branding, fixed LAN addresses, and unrelated tools are not included.

## What users actually need to enter

The defaults cover local ports, directories, provider/group names, logs, polling, and 30-day retention. Normal users do not need to fill in a large configuration form.

| Scenario | Required input | Automated | Optional |
| --- | --- | --- | --- |
| Existing CF ProxyTunnel | The `ADMIN` password; one site URL only for deployments made elsewhere | Sign in to the Worker, derive the subscription, generate local config, and start all services | Allowing a trusted LAN |
| No CF ProxyTunnel yet | None | Open the deployment guide, then rerun `START.cmd` after setup | Wrangler or manual tutorial deployment |
| Deploy EdgeTunnel to Cloudflare | One `ADMIN` password | Wrangler login, Worker build, KV provisioning, and the `KV` binding | Custom domain |
| Local Mihomo | `bin\mihomo.exe` or an existing advanced-config path | Generate the main-pool config and Controller secret | Probes and advanced ports |

Cloudflare sign-in is a one-time browser authorization, not a project field. Users do not copy a KV namespace ID: current Wrangler versions automatically provision the namespace and bind it as `KV`. EdgeTunnel derives its UUID, subscription token, and Clash URL from `ADMIN`; `START.cmd` retrieves them after login, so users do not copy them.

> A complete proxy runtime still needs Mihomo and a CF ProxyTunnel deployment you are authorized to manage. This repository intentionally does not bundle proxy binaries, derived subscriptions, or production secrets.

## Project status

| Area | Status | Notes |
| --- | --- | --- |
| Go backend | Builds and tests | Monitoring, catalog, egress verification, and control APIs |
| Web UI | Runnable | Desktop/narrow layouts, themes, page navigation, and job progress |
| Windows management adapter | Alpha | Still depends on PowerShell 7, Windows Scheduled Tasks, and Mihomo |
| EdgeTunnel integration | Pinned and auditable | A pinned submodule plus a deterministic build patch removes request-global state and the live remote admin UI |
| Wrangler validation | Available | Local development, dry-run, and startup profiling |
| Complete runtime onboarding | Alpha | Splits existing-CF and no-CF paths; never creates an account or deploys silently |
| Public Internet security | Unsupported | Proper admin authentication, CSRF tokens, rate limits, and stronger auditing are missing |
| Root license | GPL-2.0-only | Compatible with the pinned EdgeTunnel upstream license |

## Features

- **Pool overview** for main/custom pools, availability, latency, traffic, connections, and active egress.
- **Candidate catalog** for ProxyIP, SOCKS5, HTTP, and HTTPS sources with pagination, search, and country filters.
- **Verified egress inspection** through isolated paths, recording the real IP, country, Cloudflare colo, and latency instead of trusting node labels.
- **Bulk and automatic selection** with bounded concurrency, persistent cursors, and failed-candidate skipping.
- **Named custom pools** built from a source, country, target route count, and selected outputs.
- **Multiple output formats** from the same pool: LAN proxy port, Clash YAML, and v2rayN Base64 subscription.
- **Isolated activation and rollback** so failed custom-pool builds retain the previous working version.
- **Reusable pool history** with saved configuration and route snapshots.
- **Country-specific ports** based only on repeatedly verified egress results.
- **Persistent background jobs** with progress, cancellation, retry, and reload-safe status.
- **Operator history** for scans, speed tests, subscription refreshes, restarts, and configuration changes.
- **Optional Cloudflare operations adapter**, disabled unless explicitly configured.

## Architecture

```text
Cloudflare Workers / Pages
cmliu/edgetunnel data plane
            │
            │ subscriptions, configuration, health
            ▼
Mihomo main pool :7890 ────────────────────┐
Mihomo custom pool :7891                   │ Controller APIs
Mihomo isolated probes :17891 / :17901+    │
            ▲                              ▼
Windows task adapter ◀────────── Go backend :9191
            ▲                              ▲
            └──────── Web gateway :9190 ───┘
                              │
                              ▼
                            Browser
```

| Component | Location | Responsibility |
| --- | --- | --- |
| Go backend | `cmd/proxytunnel/main.go`, `cmd/proxytunnel/catalog.go` | Monitoring, catalog, egress checks, history, and control APIs |
| Web UI | `cmd/proxytunnel/web/index.html` | Dashboard, filters, pool builds, confirmation dialogs, and activity views |
| Web gateway | `scripts/windows/monitor-ui-gateway.ps1` | Exposes port 9190, aggregates APIs, runs background jobs, and serves exports |
| Custom pool manager | `scripts/windows/custom-pool-manager.ps1` | Generates Mihomo configuration and atomically activates or rolls back port 7891 |
| Build worker | `scripts/windows/pool-build-worker.ps1` | Persists build progress, cursors, cancellation, and final results |
| EdgeTunnel upstream | `third_party/edgetunnel` | Cloudflare Workers/Pages data plane |
| Mihomo | External dependency | Proxy forwarding, health checks, and node switching |

See [docs/architecture.md](docs/architecture.md) for additional details.

## Default ports

| Port | Purpose | Recommended LAN exposure |
| --- | --- | --- |
| `9190` | Web UI and Windows gateway | Yes, trusted LAN only |
| `9191` | Go backend API | No, keep on loopback |
| `7890` | Mihomo main proxy | Only when required |
| `7891` | Mihomo custom-pool proxy | Only when required |
| `9090` | Main Mihomo Controller | No |
| `17891` | Isolated probe proxy | No |
| `19091` | Isolated probe Controller | No |
| `19092` | Custom-pool Controller | No |
| `17901+` | Country-specific proxy ports | Only explicitly enabled ports |
| `8787` | Local Wrangler development | No |

All ports are configurable. Never expose controller ports, internal APIs, or management subscriptions directly to the public Internet.

## Repository layout

```text
proxytunnel/
├─ cmd/proxytunnel/               # Go backend, tests, and embedded Web UI
├─ cloudflare/                    # Worker, Wrangler, Node dependencies, deploy launcher
├─ configs/config.example.json    # Zero-edit minimal configuration
├─ configs/config.advanced.example.json # Full advanced reference
├─ docs/                          # Architecture and Cloudflare integration docs
├─ scripts/                       # Bootstrap, build, test, and Windows adapters
├─ third_party/edgetunnel/        # Pinned Git submodule
├─ var/                           # Ignored runtime data generated by START.cmd
├─ START.cmd                      # The only launcher a normal user needs
├─ STOP.cmd                       # Stops processes created by START.cmd
├─ README.md                      # Chinese guide
└─ README_EN.md                   # English guide; switch languages at the top
```

## Requirements

Normal local use requires only:

- Recommended: 64-bit Windows 11 or Windows Server; 64-bit Windows 10 22H2 is a best-effort target
- Go 1.26+
- PowerShell 7.4+ (the double-click launcher checks it)

Git is needed only to clone or update the source. A working local proxy additionally requires Mihomo and your own CF ProxyTunnel. `START.cmd` signs in with the site address and `ADMIN`, then configures the Clash subscription automatically instead of reporting an empty console as usable. Node.js 22+, npm, and a Cloudflare account are needed only for Cloudflare Worker development or deployment. Docker Desktop is not required.

Windows 10 can run the project. “The complete runtime adapter currently supports Windows only” means that Linux and macOS adapters are not available yet; it does not mean Windows 11 is required. Older Windows 10 releases are outside the compatibility target.

## Quick start: choose your situation

### 1. Clone the repository

```powershell
git clone --recurse-submodules https://github.com/suakitsu/proxytunnel.git
```

### 2A. You already have CF ProxyTunnel

1. Place Mihomo at `bin\mihomo.exe`, or provide an existing path in advanced configuration.
2. Double-click `START.cmd` and choose “existing.”
3. A site deployed by this repository's `cloudflare\DEPLOY.cmd` is reused automatically. For another deployment, paste its home or `/admin` URL once.
4. Enter the same **`ADMIN` password** used during deployment in the masked prompt.

The launcher signs in to your Worker, reads its runtime `HOST`/`UUID`, and derives the correct Clash subscription automatically. `ADMIN` exists only in memory and is never stored; the site and derived subscription stay under ignored `var/`. It then generates a local Mihomo main-pool config and random Controller secret and starts ports `7890`, `9090`, `9191`, and `9190`. It reports “ready for use” only after all layers respond:

```text
Dashboard: http://127.0.0.1:9190/
Local proxy: http://127.0.0.1:7890
```

Afterward, double-click `START.cmd` to reopen the running instance. Double-click `STOP.cmd` to stop processes created by the launcher.

### 2B. You do not have CF ProxyTunnel

Choose “no” in `START.cmd`. It does not start an unusable empty dashboard; it opens:

- the [CF ProxyTunnel / EdgeTunnel illustrated deployment guide](https://www.freedidi.com/23618.html); or
- the repository's `cloudflare\DEPLOY.cmd` for the controlled Wrangler path.

After deployment, rerun `START.cmd` and enter the same `ADMIN` password using path 2A. There is no need to find or copy a Clash subscription URL.

If Mihomo is missing, the launcher likewise opens its official Releases page and shows the expected executable path. It never downloads an unpinned proxy binary, signs in to Cloudflare, creates an account, or changes online resources silently.

<details>
<summary>Developer: manual configuration, build, and startup</summary>

Initialize local configuration and directories:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

Build the backend:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
```

Start the backend manually:

```powershell
.\dist\proxytunnel.exe -config .\config.local.json
```

Start the Web gateway in another PowerShell window:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\monitor-ui-gateway.ps1 `
  -ListenPrefix 'http://127.0.0.1:9190/' `
  -AllowedCIDR '127.0.0.0/8'
```

Only Cloudflare/Worker development requires the full bootstrap:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1
```

See [configs/config.advanced.example.json](configs/config.advanced.example.json) for advanced local configuration. The repository does not distribute Mihomo binaries, production subscriptions, or Controller secrets.

</details>

## LAN access

Expose only port `9190` to the LAN where possible. Keep port `9191` and all Mihomo Controller ports on loopback.

Example for a trusted `192.168.1.0/24` network:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\monitor-ui-gateway.ps1 `
  -ListenPrefix 'http://+:9190/' `
  -AllowedCIDR '192.168.1.0/24'
```

Restrict the Windows firewall rule to the same network. Apply equivalent source restrictions to ports `7890`, `7891`, and any country-specific ports that are enabled.

## Configuration reference

### Core service

| Key | Description |
| --- | --- |
| `data_dir` | Root for all default runtime paths; defaults to `var` beside the configuration file |
| `listen` | Go backend listen address; `127.0.0.1:9191` is recommended |
| `controller_url` | Main Mihomo Controller URL |
| `controller_secret_file` | File containing the main Controller secret |
| `provider_name` | Mihomo provider name |
| `group_name` | Mihomo proxy group used for switching nodes |
| `proxy_url` | Main HTTP proxy URL, usually port 7890 |
| `egress_trace_url` | Endpoint used to determine the real egress |
| `proxy_config_file` | Main Mihomo configuration path |
| `provider_file` | Main provider file path |
| `proxy_task_name` | Windows Scheduled Task name for the main pool |
| `allowed_cidr` | Network allowed to invoke mutating backend APIs |

### Monitoring and history

| Key | Description |
| --- | --- |
| `history_dir` | Snapshot and action-history directory |
| `log_file` | Go backend log file |
| `poll_seconds` | Mihomo status polling interval |
| `egress_sample_seconds` | Main-pool egress sampling interval |
| `history_seconds` | Snapshot persistence interval |
| `retention_days` | Number of days to retain history |
| `cloudflare_health_url` | Optional EdgeTunnel health endpoint |

### Isolated probe and country ports

| Key | Description |
| --- | --- |
| `probe_controller_url` | Isolated probe Controller URL |
| `probe_secret_file` | Isolated probe Controller secret file |
| `probe_provider_name` | Probe provider name |
| `probe_group_name` | Probe proxy group name |
| `probe_proxy_url` | Isolated probe proxy URL |
| `probe_trace_url` | Egress trace URL used by the probe |
| `probe_result_file` | Persisted probe result document |
| `probe_config_file` | Probe Mihomo configuration path |
| `probe_provider_file` | Probe provider path |
| `probe_task_name` | Windows Scheduled Task name for the probe |
| `mihomo_executable` | Path to the Mihomo executable |
| `country_port_state_file` | Persisted country-port assignments |
| `country_port_base` | Starting port for country-specific proxies |

### Candidate and Cloudflare operations

| Key | Description |
| --- | --- |
| `candidate_state_file` | Verified candidates, selections, and persistent cursor state |
| `cloudflare_ops_url` | Optional Cloudflare operations adapter URL; empty disables it |
| `cloudflare_ops_token_file` | Token file for the operations adapter; never commit it |

See [configs/config.example.json](configs/config.example.json) for the normal zero-edit file and [configs/config.advanced.example.json](configs/config.advanced.example.json) for every override. Relative paths are resolved from the configuration file's directory, so startup from a different working directory cannot silently redirect runtime data.

## Cloudflare and EdgeTunnel

ProxyTunnel uses [`cmliu/edgetunnel`](https://github.com/cmliu/edgetunnel) as its Cloudflare data plane. The submodule is pinned to:

```text
92fc6cc4a4cbfdf536394bc9b0397e5948b039f8
```

The supplied [deployment article](https://www.freedidi.com/23618.html) describes a manual Pages workflow. ProxyTunnel keeps the same EdgeTunnel data plane but reduces the common deployment path to:

1. Double-click `cloudflare\DEPLOY.cmd`.
2. Read the production-impact summary and type `DEPLOY`.
3. Complete one Wrangler browser sign-in when needed.
4. Enter one `ADMIN` password of at least 12 characters.
5. Wrangler dry-runs the Worker, automatically provisions/binds `KV`, then deploys.
6. Add a custom domain separately only when needed; the default `workers.dev` address is sufficient.

ProxyTunnel does not copy account values, domains, or credentials from that article. Treat third-party tutorials as onboarding material; Cloudflare configuration should be checked against current official documentation and Wrangler validation.

### Local Worker validation

```powershell
Set-Location .\cloudflare
Copy-Item .\.dev.vars.example .\.dev.vars
# Change the local-only ADMIN value in cloudflare\.dev.vars
npm ci
npm run cf:dry-run
npm run cf:dev
```

`cf:dev` explicitly serves local HTTPS so EdgeTunnel's HTTPS redirect cannot loop during development. A browser warning for Wrangler's local self-signed certificate is expected.

Startup profiling:

```powershell
npm run cf:check
```

The checked-in `cloudflare/wrangler.jsonc` contains no account, route, KV namespace ID, or password. It declares only the `KV` binding; the deployment launcher requires the `ADMIN` secret. Local development uses a local KV store; the first production deployment lets Wrangler provision the account resource. Account-specific IDs are written only to the ignored `cloudflare/wrangler.production.jsonc`.

Before Wrangler bundles, `cloudflare/scripts/build-worker.mjs` generates an isolated copy from the pinned upstream source. It moves per-request dial settings into `AsyncLocalStorage` and replaces the live third-party `/login` and `/admin` dependency with the repository's own CSP-protected UI. Unique patch anchors make incompatible upstream changes fail closed. The local admin UI intentionally does not accept Cloudflare Global API Keys or API Tokens; use the Dashboard or Wrangler for account operations.

The deployment launcher performs a dry-run and requires explicit confirmation. It does not delete Workers, KV data, routes, domains, or unrelated resources. Staged rollouts and automated rollback are still future work.

See [docs/cloudflare-edgetunnel.md](docs/cloudflare-edgetunnel.md) for more details.

## Development and validation

Run local validation:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

Include the Cloudflare Worker dry-run:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\test.ps1 `
  -IncludeCloudflare
```

The validation covers `gofmt`, `go test ./...`, `go vet ./...`, AST parsing of every PowerShell script, deterministic Worker patch generation plus JavaScript syntax checks, and the optional Wrangler dry-run.

## Security model

The alpha currently provides three basic safeguards:

1. The Go backend validates mutating requests against `allowed_cidr`.
2. The Web gateway validates clients against `AllowedCIDR`.
3. Mutating operations require same-origin requests and the `X-ProxyTunnel-Action: confirmed` confirmation header.

These controls reduce accidental operations and some cross-site requests, but they are not full authentication. Before public exposure, the project needs administrator authentication, CSRF tokens, rate limits, session expiry, sensitive-operation auditing, secret rotation, and trusted reverse-proxy client-IP handling.

Never commit local configuration, `.dev.vars`, API tokens, Mihomo controller secrets, credential-bearing subscriptions, `var/` runtime data, logs, browser profiles, speed-test output, build artifacts, or Wrangler local state.

See [SECURITY.md](SECURITY.md).

## Known limitations

- Complete service management is currently Windows-only.
- The PowerShell gateway and management scripts are still large and should move into Go.
- The Web UI is a single file and has not yet been split into testable components.
- Candidate sources and some verification services are external dependencies and need configurable provider interfaces.
- Tests cover configuration generation, atomic replacement, country-port assignment, and candidate parsing. Process/heartbeat recovery is implemented, but stress and fault-injection coverage remains limited.
- There is no stable installer, updater, or uninstaller.
- Production-grade user authentication is not implemented.

## Roadmap

### `0.1.x` — reproducible baseline

- Remove internal paths and production data.
- Pin the EdgeTunnel upstream version.
- Establish local builds, tests, and Wrangler dry-runs.
- Complete Chinese and English documentation.

### `0.2.x` — service and reliability

- Move jobs, locks, recovery, and state machines into Go.
- Add idempotency, crash recovery, and concurrency tests.
- Provide a proper Windows Service installer.
- Convert candidate sources into configurable providers.

### `0.3.x` — public deployment readiness

- Add administrator authentication, CSRF tokens, and rate limiting.
- Add Linux/systemd or container deployment.
- Add staged Cloudflare deployment and rollback.
- Publish signed, checksummed release artifacts.
- Continue third-party license review for every dependency update.

## Licensing and third-party software

ProxyTunnel is licensed under [GNU GPL version 2](LICENSE) (`GPL-2.0-only`). Modified or redistributed copies must follow the source, copyright, and license-preservation requirements in that license.

`third_party/edgetunnel` is an independent Git submodule licensed under GPL-2.0. Preserve its source, license, and upstream notices when redistributing it. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for additional notices.

## Troubleshooting

### `Monitor backend request failed`

Verify that the Go backend is listening on `127.0.0.1:9191`, the gateway `BackendBase` matches it, the Controller secret file exists, and the Mihomo Controller is reachable.

### Port 9190 cannot start

Common causes are URL ACL permissions or an existing listener. Verify the selected port and configure a precise URL ACL with administrative rights. Avoid unrestricted public prefixes.

### The EdgeTunnel submodule is empty

```powershell
git submodule update --init --recursive
```

### PowerShell blocks script execution

Use the provided `.cmd` launchers, or apply `-ExecutionPolicy Bypass` to the current command only:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File <script.ps1>
```

This does not permanently relax the machine-wide execution policy.

### Wrangler shows a local `KV` binding without an ID

This is expected. Wrangler uses a local persistent namespace for development and can automatically provision the production KV resource during the confirmed deployment. No account-specific namespace ID is committed.
