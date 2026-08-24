/**
 * Cloudflare Pages Function: 延迟测试与数据中心识别接口
 * 
 * 专为 CloudflareSpeedTest 的 -httping 与 -cfcolo 模式设计：
 * 1. 毫秒级极速响应，CPU 占用微秒级。
 * 2. 自动在响应头与 JSON 正文中携带 CF-Ray 和机房 Colo 信息。
 */

export async function onRequest(context) {
  const { request } = context;

  // 处理 OPTIONS
  if (request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Max-Age': '86400',
      },
    });
  }

  const ray = request.headers.get('cf-ray') || '';
  const colo = (request.cf && request.cf.colo) || (ray ? ray.split('-').pop() : 'UNKNOWN');
  const clientIP = request.headers.get('cf-connecting-ip') || '';

  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
    'Access-Control-Allow-Headers': '*',
    'X-CF-Colo': colo,
    'Timing-Allow-Origin': '*',
  };

  if (request.method === 'HEAD') {
    return new Response(null, { status: 200, headers });
  }

  const payload = JSON.stringify({
    status: 'ok',
    timestamp: Date.now(),
    colo: colo,
    ray: ray,
    ip: clientIP,
  });

  return new Response(payload, { status: 200, headers });
}
