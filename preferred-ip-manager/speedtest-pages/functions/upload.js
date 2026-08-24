/**
 * Cloudflare Pages Function: 上传测速接口
 * 
 * 流式读取上传的数据并统计总大小，不积压内存。
 */

export async function onRequest(context) {
  const { request } = context;

  if (request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, PUT, OPTIONS',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Max-Age': '86400',
      },
    });
  }

  if (request.method !== 'POST' && request.method !== 'PUT') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  let receivedBytes = 0;
  if (request.body) {
    const reader = request.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      receivedBytes += value ? value.length : 0;
    }
  }

  return new Response(JSON.stringify({
    status: 'ok',
    uploadedBytes: receivedBytes,
    uploadedMB: (receivedBytes / (1024 * 1024)).toFixed(2),
  }), {
    status: 200,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
    },
  });
}
