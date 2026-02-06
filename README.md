# Auto-Mihomo

Automated [Mihomo (Clash Meta)](https://wiki.metacubex.one) subscription manager for Raspberry Pi 5.

Downloads Clash subscriptions, tests all node latencies concurrently, selects the fastest node, generates Mihomo config, and exposes an HTTP API for external systems (e.g. OpenClaw) to trigger updates and switch nodes on the fly.

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
- **Concurrent latency testing** — TCP connect test all nodes in parallel, pick the fastest
- **Config generation** — produces a complete Mihomo config with DNS, proxy groups, and GeoIP rules
- **Hot reload** — applies new config via Mihomo REST API without restarting the process
- **System proxy** — writes `/etc/profile.d/proxy.sh` so all shell tools (git, curl, apt) use the proxy
- **MCP HTTP API** — REST endpoints for OpenClaw or other systems to trigger updates and switch nodes
- **Scheduled updates** — cron job runs daily at 03:00
- **Offline deployment** — build a self-contained tarball on a dev machine, deploy to a Pi with no internet
- **OpenClaw skill** — included skill definition for AI agent integration

## Architecture

```
Raspberry Pi 5
┌─────────────────────────────────────────────┐
│                                             │
│  update_sub.sh  ─── orchestrates ──────┐    │
│       │                                │    │
│       ├── test_nodes.py   (TCP测试)    │    │
│       ├── generate_config.py (生成配置) │    │
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

### Option 1: Online install (Pi has internet)

```bash
git clone <repo-url> auto-mihomo
cd auto-mihomo
bash install.sh
```

### Option 2: Offline deploy (Pi has no internet)

```bash
# On your dev machine (macOS/Linux with internet):
bash build_package.sh                  # default: ARM64
bash build_package.sh --arch armv7     # Pi 3/4 32-bit

# Transfer to Pi:
scp dist/auto-mihomo-*.tar.gz user@pi:~/
ssh user@pi
tar xzf auto-mihomo-*.tar.gz
cd auto-mihomo
bash install.sh
```

### After installation

```bash
# 1. Set your Clash subscription URL
nano .env

# 2. Run the first update
bash scripts/update_sub.sh

# 3. Start the MCP API server
sudo systemctl start auto-mihomo-mcp

# 4. Activate proxy in current shell
source /etc/profile.d/proxy.sh

# 5. Verify
curl -I https://www.google.com
```

## Project Structure

```
auto-mihomo/
├── scripts/
│   ├── update_sub.sh          # Main orchestration script
│   ├── test_nodes.py          # Concurrent TCP latency tester
│   ├── generate_config.py     # Mihomo config generator
│   └── mcp_server.py          # MCP HTTP API server (FastAPI)
├── systemd/
│   ├── mihomo.service         # Mihomo systemd unit
│   └── auto-mihomo-mcp.service # MCP server systemd unit
├── skill/
│   └── SKILL.md               # OpenClaw agent skill definition
├── pyproject.toml             # Python project & dependencies
├── .env.example               # Environment variable template
├── version.txt                # Project version
├── install.sh                 # Installer (online + offline)
├── build_package.sh           # Offline deployment packager
└── LICENSE
```

Generated at runtime (gitignored):

```
├── config.yaml                # Mihomo config (generated)
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
| `MIHOMO_TEST_WORKERS` | `50` | Concurrent threads for latency testing |
| `MIHOMO_TCP_TIMEOUT` | `3` | TCP test timeout (seconds) |
| `MCP_SERVER_PORT` | `8900` | MCP HTTP server port |

## MCP API

Base URL: `http://<pi-ip>:8900`

Interactive API docs: `http://<pi-ip>:8900/docs`

### Endpoints

#### `POST /mcp/update` — Trigger subscription update

Runs asynchronously. Poll `/mcp/status` for progress.

```bash
curl -X POST http://localhost:8900/mcp/update
```

```json
{"status": "accepted", "message": "更新任务已提交", "timestamp": "..."}
```

#### `GET /mcp/status` — Check update status

```bash
curl http://localhost:8900/mcp/status
```

```json
{
  "update_running": false,
  "last_update_time": "2026-02-06T03:00:15Z",
  "last_update_result": {"success": true, "returncode": 0},
  "update_count": 45
}
```

#### `POST /mcp/switch` — Switch proxy node

```bash
curl -X POST http://localhost:8900/mcp/switch \
  -H "Content-Type: application/json" \
  -d '{"node": "HK-01", "group": "Proxy"}'
```

#### `GET /mcp/nodes?group=Proxy` — List nodes

```bash
curl http://localhost:8900/mcp/nodes
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
curl http://localhost:8900/mcp/health
```

## How It Works

### update_sub.sh workflow

1. **Download** — fetches subscription YAML from `MIHOMO_SUB_URL`, validates it contains `proxies`
2. **Test** — delegates to `test_nodes.py` which uses `ThreadPoolExecutor` (50 threads) to TCP-connect every node's `server:port`, measures latency in milliseconds
3. **Generate** — delegates to `generate_config.py` which builds a complete Mihomo config: DNS (fake-ip + DoH), three proxy groups (Proxy/Auto/Fallback), GeoIP-based rules (CN direct, foreign proxied)
4. **Reload** — first tries Mihomo's `PUT /configs` API for zero-downtime hot reload; falls back to `systemctl restart`; falls back to direct `nohup` start
5. **Proxy** — writes environment variables to `/etc/profile.d/proxy.sh`
6. **Verify** — tests connectivity through the proxy via HTTP 204 check

### Privilege model

The service user runs without root. Privileged operations are handled by:

| Operation | Mechanism |
|---|---|
| Reload config | Mihomo REST API (no root) |
| Restart service | `sudoers NOPASSWD` for `systemctl {start,stop,restart} mihomo` only |
| Write proxy.sh | File pre-created and chowned to service user by `install.sh` |
| Bind network ports | systemd `AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW` |

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

`install.sh` configures a cron job:

```
0 3 * * * cd /path/to/auto-mihomo && bash scripts/update_sub.sh >> cron.log 2>&1
```

## OpenClaw Integration

An OpenClaw skill is included at `skill/SKILL.md`. To enable:

```bash
# Symlink into OpenClaw skills directory
ln -s /path/to/auto-mihomo/skill ~/.openclaw/skills/auto-mihomo

# Or configure in openclaw.json
```

Set `AUTO_MIHOMO_API=http://<pi-ip>:8900` in your OpenClaw environment.

The skill teaches the agent to check proxy health, trigger updates, and switch nodes when network requests fail.

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

## License

See [LICENSE](LICENSE).
