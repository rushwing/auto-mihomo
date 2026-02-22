'use strict';

const proxyUrl =
  process.env.GLOBAL_AGENT_HTTP_PROXY ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy;

// When loaded via NODE_OPTIONS=-r, calling process.exit() would kill the host
// process before it starts.  Guard with an if-block instead so that the absence
// of a proxy URL is a silent no-op rather than a fatal exit.
if (proxyUrl) {
  try {
    const undici = require('undici');
    const { ProxyAgent, setGlobalDispatcher, fetch } = undici;

    setGlobalDispatcher(new ProxyAgent(proxyUrl));

    // Keep all fetch() calls on the same undici instance using ProxyAgent.
    globalThis.fetch = fetch;

    console.error('[proxy-bootstrap] patched dispatcher=ProxyAgent + override global fetch');
  } catch (e) {
    console.error(
      '[proxy-bootstrap] cannot require undici:',
      e && e.message ? e.message : e
    );
  }
}
