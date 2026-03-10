'use strict';

// require('undici') must be resolved from the OpenClaw app dir, not from
// this script's location (auto-mihomo/scripts has no undici dependency).
// We walk: OPENCLAW_APP_DIR → cwd → fallback bare require (Node built-in
// or a future auto-mihomo dependency), so the bootstrap stays portable.
const path = require('path');
const { createRequire } = require('module');

function loadUndici() {
  const appDir = process.env.OPENCLAW_APP_DIR || process.cwd();
  const probe = path.join(appDir, 'package.json');
  try {
    return createRequire(probe)('undici');
  } catch (_) {}
  // fallback: bare require (works if undici is resolvable from PATH, e.g.
  // Node >= 22 ships undici internally and some setups expose it globally)
  return require('undici');
}

const hasProxy =
  process.env.HTTPS_PROXY ||
  process.env.HTTP_PROXY ||
  process.env.https_proxy ||
  process.env.http_proxy;

if (hasProxy) {
  try {
    const { EnvHttpProxyAgent, getGlobalDispatcher, setGlobalDispatcher } = loadUndici();
    const current = getGlobalDispatcher?.();
    const name = current?.constructor?.name || '';
    if (!name.includes('EnvHttpProxyAgent')) {
      setGlobalDispatcher(new EnvHttpProxyAgent());
      console.error('[proxy-bootstrap] dispatcher=EnvHttpProxyAgent');
    }
  } catch (e) {
    console.error(
      '[proxy-bootstrap] failed:',
      e && e.message ? e.message : e
    );
  }
}
