import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../web/worker.mjs';

const request = path => new Request('https://toppick.example' + path);
test('unconnected data is unavailable, not an empty successful analysis', async () => {
  const r = await worker.fetch(request('/api/recommendations'), {});
  assert.equal(r.status, 503);
  assert.equal((await r.json()).status, 'not-connected');
});
test('public routes cannot trigger collection or accept writes', async () => {
  assert.equal((await worker.fetch(request('/api/recommendations?refresh=1'), {})).status, 400);
  assert.equal((await worker.fetch(new Request('https://test/api/recommendations', {method:'POST'}), {})).status, 405);
  assert.equal((await worker.fetch(request('/api/unknown'), {})).status, 404);
});
test('static assets use the asset binding', async () => {
  const r = await worker.fetch(request('/'), {ASSETS:{fetch:async () => new Response('dashboard')}});
  assert.equal(await r.text(), 'dashboard');
});
test('upstream uses only configured credentials, validates JSON, and hides failures', async () => {
  const original = globalThis.fetch;
  const env = {DATA_API_BASE_URL:'https://origin.example', CF_ACCESS_CLIENT_ID:'id', CF_ACCESS_CLIENT_SECRET:'secret'};
  try {
    globalThis.fetch = async (url, options) => {
      assert.equal(url.href, 'https://origin.example/api/recommendations');
      assert.equal(options.redirect, 'error');
      assert.equal(options.headers['CF-Access-Client-Secret'], 'secret');
      return Response.json({items:[{code:'005930'}],generatedAt:'source-time'});
    };
    const r = await worker.fetch(request('/api/recommendations'), env);
    assert.equal((await r.json()).generatedAt, 'source-time');
    for (const invalid of [() => new Response('login page'), () => Response.json({}), () => new Response('private detail',{status:500})]) {
      globalThis.fetch = async () => invalid();
      const failed = await worker.fetch(request('/api/recommendations'), env);
      assert.equal(failed.status, 502);
      assert.equal((await failed.json()).status, 'upstream-unavailable');
    }
    assert.equal((await worker.fetch(request('/api/recommendations'), {DATA_API_BASE_URL:'http://origin.example'})).status, 502);
  } finally { globalThis.fetch = original; }
});
