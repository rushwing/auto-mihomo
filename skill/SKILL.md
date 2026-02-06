---
name: auto-mihomo
description: Manage Mihomo proxy on Raspberry Pi — update subscriptions, switch nodes, and diagnose network issues via the auto-mihomo MCP HTTP API.
user-invocable: true
metadata:
  {
    "openclaw": {
      "emoji": "🌐",
      "requires": {
        "bins": ["curl"],
        "env": ["AUTO_MIHOMO_API"]
      },
      "primaryEnv": "AUTO_MIHOMO_API"
    }
  }
---

# Auto-Mihomo Proxy Skill

Manage the Mihomo (Clash Meta) proxy running on the Raspberry Pi via its HTTP API.

## Configuration

The environment variable `AUTO_MIHOMO_API` must be set to the MCP server base URL.
Example: `AUTO_MIHOMO_API=http://192.168.1.100:8900`

## When to use this skill

- A network request fails (curl, git, apt, pip) and you suspect the proxy is down or stale.
- The user explicitly asks to update the proxy subscription or switch nodes.
- You need to verify whether the proxy is healthy before running network-dependent tasks.

## Available endpoints

All endpoints are relative to `$AUTO_MIHOMO_API`.

### Health check

```bash
curl -s "$AUTO_MIHOMO_API/mcp/health"
```

Returns `mihomo: "ok"` or `"unreachable"`. Always check health first before other operations.

### Trigger subscription update

```bash
curl -s -X POST "$AUTO_MIHOMO_API/mcp/update"
```

This runs asynchronously. Poll status afterwards:

```bash
curl -s "$AUTO_MIHOMO_API/mcp/status"
```

Wait until `update_running` is `false`, then check `last_update_result.success`.

### List available nodes

```bash
curl -s "$AUTO_MIHOMO_API/mcp/nodes?group=Proxy"
```

Returns all nodes with name, type, alive status, delay (ms), and whether it is the current node.

### Switch to a specific node

```bash
curl -s -X POST "$AUTO_MIHOMO_API/mcp/switch" \
  -H "Content-Type: application/json" \
  -d '{"node": "NODE_NAME", "group": "Proxy"}'
```

Replace `NODE_NAME` with the exact node name from the nodes list.

## Recommended workflow

1. **Check health** — call `/mcp/health`. If mihomo is unreachable, trigger an update.
2. **Trigger update** — `POST /mcp/update`, then poll `/mcp/status` every 5 seconds (max 60s).
3. **Verify** — after update completes, check health again.
4. **If still failing** — list nodes, pick one with lowest delay that is alive, and switch to it.
5. **Report** — tell the user the result: which node was selected, its latency, and whether connectivity is restored.

## Important notes

- Do NOT call `/mcp/update` if an update is already running (`update_running: true`).
- Node names may contain Unicode characters — always use the exact name from `/mcp/nodes`.
- The update process takes 30–120 seconds (downloads subscription, tests all nodes, restarts Mihomo).
- If the Raspberry Pi itself is unreachable, this skill cannot help — escalate to the user.
