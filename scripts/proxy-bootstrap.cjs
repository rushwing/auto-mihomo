'use strict';

const path = require('path');
const { createRequire } = require('module');

const proxyUrl =
  process.env.GLOBAL_AGENT_HTTP_PROXY ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy;

function resolveOpenClawAppDir() {
  if (process.env.OPENCLAW_APP_DIR) return process.env.OPENCLAW_APP_DIR;
  if (typeof process.cwd === 'function') {
    try {
      const cwd = process.cwd();
      if (cwd) return cwd;
    } catch (_) {}
  }
  if (process.env.HOME) return path.join(process.env.HOME, '.openclaw');
  return null;
}

function resolveUndici() {
  const appDir = resolveOpenClawAppDir();

  if (appDir) {
    try {
      const appRequire = createRequire(path.join(appDir, 'package.json'));
      return { undici: appRequire('undici'), source: appDir };
    } catch (_) {
      // Fall through to default resolver.
    }
  }

  return { undici: require('undici'), source: 'default-resolver' };
}

// When loaded via NODE_OPTIONS=-r, calling process.exit() would kill the host
// process before it starts.  Guard with an if-block instead so that the absence
// of a proxy URL is a silent no-op rather than a fatal exit.
if (proxyUrl) {
  try {
    const { undici, source } = resolveUndici();
    const { ProxyAgent, setGlobalDispatcher, fetch } = undici;

    setGlobalDispatcher(new ProxyAgent(proxyUrl));

    // Keep all fetch() calls on the same undici instance using ProxyAgent.
    globalThis.fetch = fetch;

    console.error(
      `[proxy-bootstrap] patched dispatcher=ProxyAgent + override global fetch (undici from ${source})`
    );
  } catch (e) {
    console.error(
      '[proxy-bootstrap] cannot require undici:',
      e && e.message ? e.message : e
    );
  }
}
