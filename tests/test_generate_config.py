#!/usr/bin/env python3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from generate_config import build_config  # noqa: E402


probe_url = "https://probe.example.test/generate_204"
config = build_config(
    proxies=[{"name": "test-node", "type": "ss"}],
    best_node="test-node",
    mixed_port=7893,
    api_port=9090,
    controller_host="127.0.0.1",
    api_secret="secret",
    proxy_mode="process-proxy",
    probe_url=probe_url,
)

groups = {group["name"]: group for group in config["proxy-groups"]}
assert groups["Auto"]["url"] == probe_url
assert groups["Fallback"]["url"] == probe_url
assert probe_url.startswith("https://")

print("PASS: generate_config HTTPS probe propagation")
