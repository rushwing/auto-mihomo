/**
 * proxy-bootstrap.js - Preload script to enable HTTP proxy for Node.js fetch()
 *
 * Node.js built-in fetch (undici) ignores HTTP_PROXY env vars by default.
 * This script patches the global dispatcher so all fetch() calls go through the proxy.
 *
 * Usage:
 *   node -r /path/to/proxy-bootstrap.js app.js
 *   NODE_OPTIONS="-r /path/to/proxy-bootstrap.js" node app.js
 *
 * Reads from: GLOBAL_AGENT_HTTP_PROXY, HTTP_PROXY, http_proxy (first found wins)
 * Requires: Node.js >= 18.x (built-in undici)
 */
'use strict';

const proxyUrl =
  process.env.GLOBAL_AGENT_HTTP_PROXY ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy;

if (proxyUrl) {
  try {
    const { ProxyAgent, setGlobalDispatcher } = require('undici');
    setGlobalDispatcher(new ProxyAgent(proxyUrl));
  } catch (_) {
    // undici not available as a direct require — skip silently
  }
}
