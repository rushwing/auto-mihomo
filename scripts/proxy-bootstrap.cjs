'use strict';

const hasProxy =
  process.env.HTTPS_PROXY ||
  process.env.HTTP_PROXY ||
  process.env.https_proxy ||
  process.env.http_proxy;

if (hasProxy) {
  try {
    const { EnvHttpProxyAgent, getGlobalDispatcher, setGlobalDispatcher } = require('undici');
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
