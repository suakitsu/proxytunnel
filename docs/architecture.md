# Architecture

ProxyTunnel separates the Cloudflare data plane from the local control plane.

```text
Cloudflare Worker/Pages (EdgeTunnel)
        │ subscription / configuration
        ▼
Mihomo main pool :7890 ───────────────┐
Mihomo custom pool :7891              │ controller APIs
Mihomo isolated probes :17891+        │
        ▲                              ▼
Windows task adapter ◀──── Go backend :9191
        ▲                              ▲
        └──────── Web gateway :9190 ───┘
                         │
                         ▼
                    Browser UI
```

## Components

- `cmd/proxytunnel/main.go` and `cmd/proxytunnel/catalog.go`: monitoring, candidate catalog, egress checks, history and control API.
- `cmd/proxytunnel/web/index.html`: embedded management UI used by the Go binary and the Windows gateway.
- `scripts/windows/monitor-ui-gateway.ps1`: Windows compatibility gateway and background-job coordinator.
- `scripts/windows/custom-pool-manager.ps1`: creates and atomically activates the isolated custom pool.
- `scripts/windows/pool-build-worker.ps1`: persistent background pool build worker.
- `third_party/edgetunnel`: pinned upstream Cloudflare Worker implementation; it is never edited in place.
- `cloudflare/scripts/build-worker.mjs`: fail-closed build patch that removes cross-request mutable state, account-credential handling, and live third-party admin-page loading.
- `cloudflare/worker/`: stable Worker entry point plus the repository-owned login/admin interface.
- `var/`: local runtime state. Its contents are intentionally ignored by Git.

The Windows gateway accepts requests on one `HttpListener` and dispatches them to a bounded runspace pool. Long node validation streams therefore do not block health, status, or navigation requests. Pool-build workers publish a PID and heartbeat; missing or stale workers are marked `interrupted`, and confirmed stale processes are terminated without replacing the last working pool.

## Current portability boundary

The recommended Windows baseline is 64-bit Windows 11 or Windows Server with PowerShell 7. Windows 10 22H2 is a best-effort compatibility target: the adapter avoids Windows 11-only APIs, but current third-party runtimes do not promise long-term support for vendor-EOL operating systems. The core monitor is Go, but task control and pool activation currently depend on Windows Scheduled Tasks and PowerShell 7. A later release should move job state, locking and process supervision into Go, leaving Windows and Linux as thin service-install adapters.
