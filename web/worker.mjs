const routes = new Set(['/api/recommendations', '/api/top3-validation', '/api/target10', '/api/progress']);
const json = (body, status = 200) => Response.json(body, {
  status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
});

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/api/')) return env.ASSETS.fetch(request);
    if (!routes.has(url.pathname)) return json({ error: 'not-found' }, 404);
    if (request.method !== 'GET') return json({ error: 'read-only' }, 405);
    // Never expose the Windows collection/refresh trigger to public requests.
    if (url.search) return json({ error: 'query-not-supported' }, 400);
    if (url.pathname === '/api/progress') return json({ status: 'idle', readOnly: true });
    if (!env.DATA_API_BASE_URL) return json({
      available: false, status: 'not-connected', items: [], top3: [],
      message: '데이터 미연결 · Windows 수집 서버 연결 설정이 필요합니다.'
    }, 503);
    try {
      const upstream = new URL(env.DATA_API_BASE_URL);
      if (upstream.protocol !== 'https:' || upstream.username || upstream.password ||
          upstream.pathname !== '/' || upstream.search || upstream.hash) throw new Error('Invalid origin');
      upstream.pathname = url.pathname;
      const headers = { Accept: 'application/json' };
      if (env.CF_ACCESS_CLIENT_ID && env.CF_ACCESS_CLIENT_SECRET) {
        headers['CF-Access-Client-Id'] = env.CF_ACCESS_CLIENT_ID;
        headers['CF-Access-Client-Secret'] = env.CF_ACCESS_CLIENT_SECRET;
      }
      const response = await fetch(upstream, {
        headers, redirect: 'error', signal: AbortSignal.timeout(15000)
      });
      if (!response.ok) throw new Error('Upstream failed');
      const body = await response.json();
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('Invalid data');
      if (url.pathname === '/api/recommendations' && !Array.isArray(body.items)) throw new Error('Invalid recommendations');
      return json(body);
    } catch {
      return json({ available: false, status: 'upstream-unavailable', items: [], top3: [],
        message: '데이터 서버 연결 실패 · 수집 서버와 접근 설정을 확인해 주세요.' }, 502);
    }
  }
};
