# Auto-Mihomo

Automated [Mihomo (Clash Meta)](https://wiki.metacubex.one) subscription manager for Raspberry Pi 5.

Downloads Clash subscriptions, probes node latencies via real HTTP traffic through Mihomo, selects the fastest node, generates Mihomo config, and exposes an HTTP API for external systems (e.g. OpenClaw) to trigger updates and switch nodes on the fly.

## Disclaimer

This project is intended **only for developers** to access restricted technical resources such as GitHub, Stack Overflow, official documentation sites, and development tool registries. It **must not** be used for any political purpose or to circumvent laws and regulations.

## Supported Subscription Formats

Any standard Clash / Clash Meta (Mihomo) YAML subscription URL is supported. The subscription must return a YAML document containing a `proxies` list. Supported proxy protocols include all types that Mihomo supports:

- **VMess** / **VLESS**
- **Shadowsocks** / **ShadowsocksR**
- **Trojan**
- **Hysteria** / **Hysteria2**
- **TUIC**
- **WireGuard**

## Features

- **Auto subscription update** — download, parse, and apply Clash subscriptions
- **HTTP probe node selection** — select nodes using real HTTP traffic through Mihomo mixed-port (not only raw TCP connect)
- **Config generation** — produces a complete Mihomo config with DNS, proxy groups, and GeoIP rules
- **Hot reload** — applies new config via Mihomo REST API without restarting the process
- **System proxy** — writes `/etc/profile.d/proxy.sh` so all shell tools (git, curl, apt) use the proxy
- **MCP HTTP API** — REST endpoints for OpenClaw or other systems to trigger updates and switch nodes
- **Scheduled updates** — cron job runs daily at 12:00 (Beijing time / `Asia/Shanghai`)
- **Offline deployment** — build a self-contained tarball on a dev machine, deploy to a Pi with no internet
- **OpenClaw skill** — included skill definition for AI agent integration
- **Secret rotation helpers** — generate secrets, sync to 1Password, and one-shot rotate/restart
- **Post-deploy self-check** — verify Mihomo/MCP/OpenClaw services and GitHub/Google/Telegram proxy chain

## Architecture

```
Raspberry Pi 5
┌─────────────────────────────────────────────┐
│                                             │
│  update_sub.sh  ─── orchestrates ──────┐    │
│       │                                │    │
│       ├── generate_config.py (生成配置) │    │
│       ├── HTTP probe select  (HTTP测速) │    │
│       │                                ▼    │
│       └──────────────────────►  Mihomo      │
│                                :7893 proxy  │
│                                :9090 API    │
│                                             │
│  mcp_server.py ─── FastAPI ──► :8900        │
│       │                                     │
│       ├── POST /mcp/update   (更新订阅)     │
│       ├── GET  /mcp/status   (查询状态)     │
│       ├── POST /mcp/switch   (切换节点)     │
│       ├── GET  /mcp/nodes    (节点列表)     │
│       └── GET  /mcp/health   (健康检查)     │
│                                             │
└─────────────────────────────────────────────┘
         ▲
         │ HTTP
         │
   OpenClaw / curl / other systems
```

## Quick Start

### Fresh install

```bash
# On your dev machine — build a self-contained offline package:
bash build_package.sh                  # default: ARM64 (Pi 5)
bash build_package.sh --arch armv7     # Pi 3/4 32-bit

# Transfer and install on the Pi:
scp dist/auto-mihomo-*.tar.gz user@pi:~/
ssh user@pi
tar xzf auto-mihomo-*.tar.gz
sudo bash auto-mihomo/upgrade.sh       # auto-detects: no existing install → runs install.sh
```

Or directly from source on a Pi that has internet access:

```bash
git clone <repo-url> auto-mihomo
sudo bash auto-mihomo/upgrade.sh
```

### Upgrading an existing install

```bash
# Build and ship the new package (same as above), then on the Pi:
tar xzf auto-mihomo-*.tar.gz
sudo bash auto-mihomo/upgrade.sh       # stops services, migrates .env, deploys, restarts
```

`upgrade.sh` guides you through any `.env` changes interactively and always backs up the previous installation before touching anything.

> **Single entry point:** Always run `upgrade.sh`. It auto-detects whether this is a fresh install or an upgrade and acts accordingly. If you run `install.sh` on a machine that already has an installation, it will redirect you to `upgrade.sh`.

### After installation

```bash
# 1. Set your Clash subscription URL (prompted by the wizard on first run)
nano /opt/auto-mihomo/.env

# 2. Run the first update (as service user)
sudo -u openclaw bash /opt/auto-mihomo/scripts/update_sub.sh

# 3. Start services (OpenClaw gateway will run update_sub.sh first via wrapper)
sudo systemctl start auto-mihomo-mcp
sudo systemctl start openclaw-gateway

# 4. Optional: activate proxy in current shell (for manual curl/git/apt)
source /etc/profile.d/proxy.sh

# 5. Run post-deploy self-check
bash /opt/auto-mihomo/scripts/post_deploy_self_check.sh
```

## Deployment Paths

### Standard production layout

| Path | Purpose |
|---|---|
| `/opt/auto-mihomo/` | auto-mihomo install directory (scripts, config, logs, `.venv`) |
| `/opt/mihomo/` | Mihomo binary and GeoIP data |
| `/home/<user>/.openclaw/` | OpenClaw app/state directory (detection trigger: `dist/index.js`, fallback `openclaw.mjs`) |

`install.sh` always deploys the project to `/opt/auto-mihomo/` regardless of where the script is run from. The script directory is only used as the source for the rsync copy.

- **Development / testing** — run `sudo bash install.sh` from any directory (e.g. after unpacking to `/tmp/auto-mihomo-v1.2/`); files land at `/opt/auto-mihomo/`.
- **Production** — the running installation is always at the fixed path `/opt/auto-mihomo/`, so service files, cron jobs, and log paths are stable and predictable.

> `upgrade.sh` works the same way: unpack the new package anywhere, run `sudo bash upgrade.sh` from that directory, and it deploys into the existing `/opt/auto-mihomo/` (detected via the systemd `WorkingDirectory=` field).

## Project Structure

```
auto-mihomo/
├── scripts/
│   ├── update_sub.sh          # Main orchestration script
│   ├── test_nodes.py          # TCP latency tester (legacy; node selection now uses HTTP probe in update_sub.sh)
│   ├── generate_config.py     # Mihomo config generator
│   ├── mcp_server.py          # MCP HTTP API server (FastAPI)
│   ├── proxy-bootstrap.cjs    # Preloaded via NODE_OPTIONS to set undici EnvHttpProxyAgent
│   ├── start_openclaw_with_proxy.sh # Wrapper: update then start OpenClaw
│   ├── cron_update_proxy.sh   # Daily noon update cron target
│   ├── post_deploy_self_check.sh # Service + proxy chain checks
│   ├── generate_secrets.sh    # Generate MIHOMO/MCP secrets
│   ├── sync_secrets_to_1password.sh # Sync .env secrets to 1Password
│   └── rotate_secrets_and_restart.sh # One-shot rotate/sync/restart/check
├── systemd/
│   ├── mihomo.service              # Mihomo systemd unit
│   ├── auto-mihomo-mcp.service     # MCP server systemd unit
│   └── openclaw-gateway.service.d/
│       └── 10-auto-mihomo.conf     # Drop-in overlay for openclaw-gateway (proxy env + ExecStartPre)
├── skill/
│   └── SKILL.md               # OpenClaw agent skill definition
├── pyproject.toml             # Python project & dependencies
├── .env.example               # Environment variable template
├── version.txt                # Project version
├── install.sh                 # Installer (online + offline; redirects to upgrade.sh if existing install detected)
├── upgrade.sh                 # Upgrade wizard (migrates .env, updates files, restarts services)
├── build_package.sh           # Offline deployment packager
└── LICENSE
```

Generated at runtime (gitignored):

```
├── config.yaml                # Compatibility symlink to Mihomo config (generated)
├── subscription.yaml          # Downloaded subscription (generated)
├── uv.lock                    # Dependency lock file
└── .venv/                     # Python virtual environment
```

## Configuration

Copy `.env.example` to `.env` and edit:

```bash
cp .env.example .env
nano .env
```

| Variable | Default | Description |
|---|---|---|
| `MIHOMO_SUB_URL` | *(required)* | Clash/ClashMeta YAML subscription URL |
| `MIHOMO_BIN` | `/opt/mihomo/mihomo` | Mihomo binary path |
| `MIHOMO_HOME` | `/opt/mihomo` | Mihomo data directory (GeoIP files) |
| `MIHOMO_MIXED_PORT` | `7893` | HTTP + SOCKS5 mixed proxy port |
| `MIHOMO_API_PORT` | `9090` | Mihomo RESTful API port |
| `MIHOMO_CONTROLLER_HOST` | `127.0.0.1` | Mihomo controller listen host (recommended localhost only) |
| `MIHOMO_API_SECRET` | `CHANGE_ME...` | Mihomo REST API Bearer secret |
| `AUTO_MIHOMO_PROXY_MODE` | `process-proxy` | `process-proxy` (OpenClaw/service proxy); `gateway-proxy` (transparent LAN gateway — DNS and proxy bind to all interfaces) |
| `MIHOMO_HTTP_PROBE_URL` | `http://www.gstatic.com/generate_204` | HTTP probe URL used for node selection via the local mixed-port |
| `MIHOMO_HTTP_PROBE_TIMEOUT` | `12` | Probe timeout in seconds |
| `MCP_SERVER_PORT` | `8900` | MCP HTTP server port |
| `MCP_SERVER_HOST` | `127.0.0.1` | MCP listen host (recommended localhost only) |
| `MCP_API_TOKEN` | `CHANGE_ME...` | MCP API Bearer token |

## MCP API

Base URL (default localhost-only): `http://127.0.0.1:8900`

Interactive API docs: `http://127.0.0.1:8900/docs`

If `MCP_API_TOKEN` is set, all `/mcp/*` endpoints require:

```bash
-H "Authorization: Bearer <MCP_API_TOKEN>"
```

### Endpoints

#### `POST /mcp/update` — Trigger subscription update

Runs asynchronously. Poll `/mcp/status` for progress.

```bash
curl -X POST http://localhost:8900/mcp/update \
  -H "Authorization: Bearer <MCP_API_TOKEN>"
```

```json
{"status": "accepted", "message": "更新任务已提交", "timestamp": "..."}
```

#### `GET /mcp/status` — Check update status

```bash
curl http://localhost:8900/mcp/status \
  -H "Authorization: Bearer <MCP_API_TOKEN>"
```

```json
{
  "update_running": false,
  "last_update_time": "2026-02-06T12:00:15+08:00",
  "last_update_result": {"success": true, "returncode": 0},
  "update_count": 45
}
```

#### `POST /mcp/switch` — Switch proxy node

```bash
curl -X POST http://localhost:8900/mcp/switch \
  -H "Authorization: Bearer <MCP_API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"node": "HK-01", "group": "Proxy"}'
```

#### `GET /mcp/nodes?group=Proxy` — List nodes

```bash
curl http://localhost:8900/mcp/nodes \
  -H "Authorization: Bearer <MCP_API_TOKEN>"
```

```json
{
  "group": "Proxy",
  "current": "HK-01",
  "total": 12,
  "nodes": [
    {"name": "HK-01", "type": "vmess", "alive": true, "delay": 45, "current": true},
    {"name": "SG-02", "type": "vless", "alive": true, "delay": 67, "current": false}
  ]
}
```

#### `GET /mcp/health` — Health check

```bash
curl http://localhost:8900/mcp/health \
  -H "Authorization: Bearer <MCP_API_TOKEN>"
```

## How It Works

### update_sub.sh workflow

1. **Download** — fetches subscription YAML from `MIHOMO_SUB_URL`, validates it contains `proxies`
2. **Bootstrap node** — selects the first subscription node as a temporary default (used to bring Mihomo up before probing)
3. **Generate** — delegates to `generate_config.py` which builds a complete Mihomo config (written to Mihomo workdir, e.g. `/opt/mihomo/config.yaml`): DNS (fake-ip + DoH, localhost-bound in `process-proxy` mode), proxy groups, GeoIP rules, controller host/secret
4. **Reload** — first tries Mihomo's `PUT /configs?force=true` API (with Bearer secret if configured); falls back to `systemctl restart`; falls back to direct `nohup` start
5. **HTTP Probe Select** — iterates nodes sequentially: switches each node via Mihomo API, then sends a real HTTP request through the local mixed-port; picks the lowest-latency responsive node and reloads config with it as default
6. **Proxy (process-proxy mode)** — writes environment variables to `/etc/profile.d/proxy.sh` and `/etc/auto-mihomo/proxy.env`
7. **Verify** — tests connectivity through the proxy via `MIHOMO_HTTP_PROBE_URL`

### Service user and privilege model

`install.sh` accepts a `--user` flag to specify which user runs all services:

```bash
sudo bash install.sh --user openclaw
```

This sets ownership on all required paths and configures sudoers/systemd accordingly. The service user runs without root. Privileged operations are handled by:

| Operation | Mechanism |
|---|---|
| Reload config | Mihomo REST API (no root) |
| Restart service | `sudoers NOPASSWD` for `systemctl {start,stop,restart} mihomo` only |
| Write proxy.sh | File pre-created and chowned to service user by `install.sh` |
| Write proxy.env | `/etc/auto-mihomo/` directory chowned to service user by `install.sh` |
| Bind network ports | systemd `AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW` |

Paths owned by the service user:

| Path | Purpose |
|---|---|
| `/opt/auto-mihomo` | Project directory (scripts, config, logs) |
| `/opt/mihomo` | Mihomo binary and GeoIP data |
| `/etc/auto-mihomo/` | Proxy environment files for systemd services |
| `/etc/profile.d/proxy.sh` | Proxy environment for login shells |

### Generated proxy groups

| Group | Type | Behavior |
|---|---|---|
| `Proxy` | select | Manual selection; defaults to fastest node |
| `Auto` | url-test | Automatic selection by latency (300s interval, 50ms tolerance) |
| `Fallback` | fallback | Auto-failover ordered by latency |

### Routing rules

```
GEOIP,private  → DIRECT
GEOSITE,cn     → DIRECT
GEOIP,CN       → DIRECT
GEOSITE,google/github/twitter/telegram/youtube → Proxy
MATCH          → Proxy
```

## Scheduled Updates

`install.sh` configures a cron job (Beijing time / `Asia/Shanghai`) and de-duplicates existing entries:

```
CRON_TZ=Asia/Shanghai
0 12 * * * /path/to/auto-mihomo/scripts/cron_update_proxy.sh
```

## OpenClaw Integration

### Gateway service with proxy

auto-mihomo does **not** own the `openclaw-gateway.service` base unit — that is installed and managed by OpenClaw itself (`openclaw onboard --install-daemon`). auto-mihomo only installs a thin **systemd drop-in** at:

```
/etc/systemd/system/openclaw-gateway.service.d/10-auto-mihomo.conf
```

The drop-in adds three things to the base unit:

| Directive | Purpose |
|-----------|---------|
| `Wants=mihomo.service` / `After=mihomo.service` | Ensures Mihomo is up before gateway starts; `Wants=` (not `Requires=`) avoids restart cascades |
| `EnvironmentFile=/etc/auto-mihomo/proxy.env` | Injects `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` (refreshed by `update_sub.sh`) |
| `Environment=NODE_OPTIONS=-r .../proxy-bootstrap.cjs` | Preloads undici `EnvHttpProxyAgent` so all `fetch()` calls route through Mihomo |
| `ExecStartPre=-bash .../scripts/update_sub.sh` | Runs a subscription update before the gateway starts; `-` prefix tolerates failure |

`install.sh` / `upgrade.sh` install the drop-in automatically when `~/.openclaw` is detected. No manual step is needed. The base unit is **never** installed, enabled, or modified by auto-mihomo.

**First-time setup:** if `openclaw-gateway.service` does not exist yet on the system, run `openclaw onboard --install-daemon` after `install.sh` to register the base unit, then `sudo systemctl daemon-reload && sudo systemctl start openclaw-gateway`.

**Upgrading from an older auto-mihomo:** if `/etc/systemd/system/openclaw-gateway.service` still exists from a previous install (it used `start_openclaw_with_proxy.sh` as `ExecStart`), `upgrade.sh` will print a migration guide. Clean it up manually:

```bash
sudo systemctl stop openclaw-gateway
sudo rm /etc/systemd/system/openclaw-gateway.service
openclaw onboard --install-daemon
sudo systemctl daemon-reload && sudo systemctl start openclaw-gateway
```

### Agent skill

An OpenClaw skill is included at `skill/SKILL.md`. To enable:

```bash
# Symlink into OpenClaw skills directory
ln -s /path/to/auto-mihomo/skill ~/.openclaw/skills/auto-mihomo
```

Set `AUTO_MIHOMO_API=http://127.0.0.1:8900` in your OpenClaw environment (default localhost-only deployment).

If you need remote access from another machine, set `MCP_SERVER_HOST=0.0.0.0` and keep `MCP_API_TOKEN` enabled.

The skill teaches the agent to check proxy health, trigger updates, and switch nodes when network requests fail.

## Secrets and 1Password

### Generate local secrets

Generate `MIHOMO_API_SECRET` and `MCP_API_TOKEN`:

```bash
bash scripts/generate_secrets.sh --write-env
```

### Sync secrets and subscription URL to 1Password

Store these fields in a 1Password item (recommended labels use the same names):

- `MIHOMO_SUB_URL`
- `MIHOMO_API_SECRET`
- `MCP_API_TOKEN`

Sync from `.env` to an existing item:

```bash
bash scripts/sync_secrets_to_1password.sh --vault auto-mihomo --item raspi-prod
```

### One-shot rotation (generate → sync → restart → health check)

```bash
bash scripts/rotate_secrets_and_restart.sh --vault auto-mihomo --item raspi-prod
```

Useful flags:

- `--skip-sync`
- `--skip-restart`
- `--skip-health`

## Post-Deploy Self-Check

Run the built-in self-check script after deployment or after secret rotation:

```bash
bash scripts/post_deploy_self_check.sh
```

It verifies:

- `mihomo` and `auto-mihomo-mcp` systemd services (always checked)
- `openclaw-gateway` systemd service (checked only if the service file is installed — skipped cleanly on non-OpenClaw machines)
- Mihomo local API (`/version`)
- MCP local API (`/mcp/health`)
- Proxy chain to GitHub, Google, and Telegram API via Mihomo mixed-port

## Build Package

`build_package.sh` creates a self-contained tarball for offline deployment:

```bash
bash build_package.sh                    # ARM64 (Pi 5)
bash build_package.sh --arch armv7       # ARMv7 (Pi 3/4)
bash build_package.sh --arch amd64       # x86_64
bash build_package.sh --mihomo v1.19.0   # Specific Mihomo version
bash build_package.sh --py 3.12          # Target Python version
```

The package includes pre-downloaded:
- Mihomo binary (target architecture)
- GeoIP databases (geoip.dat, geosite.dat, country.mmdb)
- uv package manager (target architecture)
- Python dependency wheels (target architecture)

Output: `dist/auto-mihomo-<version>-<arch>-<commit>.tar.gz`

## Supported Platforms

| Architecture | Hardware | Build flag |
|---|---|---|
| ARM64 (aarch64) | Raspberry Pi 5, Pi 4 64-bit | `--arch arm64` (default) |
| ARMv7 (armv7l) | Raspberry Pi 3/4 32-bit | `--arch armv7` |
| x86_64 (amd64) | Intel/AMD servers | `--arch amd64` |

## Changelog

### v1.1.0

- **`upgrade.sh`** — new upgrade wizard: stops services, backs up current install, runs interactive `.env` migration (detects added/removed keys, prompts for `MIHOMO_SUB_URL` / `MIHOMO_API_SECRET` / `MCP_API_TOKEN`), deploys new files, updates systemd units, restarts services, and runs post-deploy self-check
- **Single entry point** — both `install.sh` and `upgrade.sh` detect whether an existing installation is present and redirect to the appropriate script, so either can be run without knowing the current state
- **Hot reload fix** — `PUT /configs` changed to `PUT /configs?force=true`; Mihomo v1.19.x requires the `force` query parameter to accept a reload of a running config, fixing the HTTP 400 that previously caused every startup to fall back to a full service restart
- **Restart loop fix** — `openclaw-gateway.service` changed from `Requires=mihomo.service` to `Wants=mihomo.service`; `Requires=` caused a cascade-stop of OpenClaw whenever Mihomo restarted, which re-ran `update_sub.sh`, which tried to reload again — infinite loop
- **OpenClaw binary path fix** — `install.sh` and `upgrade.sh` now detect OpenClaw via `~/.openclaw/dist/index.js` first, with `~/.openclaw/openclaw.mjs` as legacy fallback

### v1.0.2

- Update mihomo to v1.19.20

### v1.0.1

- Parallel TCP pre-filter, HTTP probe node selection strategy
- Fix openclaw binary path

### v1.0.0

- Initial release: process-proxy mode, MCP HTTP API, secret rotation

## License

See [LICENSE](LICENSE).
