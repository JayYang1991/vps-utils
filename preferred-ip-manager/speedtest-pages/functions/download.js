/**
 * Cloudflare Pages Function: 动态流式下载测速接口
 * 
 * 极致资源节约设计：
 * 1. 采用 ReadableStream 流式生成，单次仅复用 64KB 内存缓冲区，内存占用恒定 < 1MB。
 * 2. 纯流式写入避免在 Worker 内存中拼装大 ArrayBuffer，CPU 消耗微秒级，完美契合 Cloudflare 免费版限制。
 * 3. 支持 ?size=50 参数（单位 MB，默认 50MB，上限 500MB）。
 */

export async function onRequest(context) {
  const { request } = context;

  // 处理 OPTIONS 跨域预检请求
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

  // 仅支持 GET 与 HEAD
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  const url = new URL(request.url);
  let sizeMB = parseFloat(url.searchParams.get('size') || '50');
  if (isNaN(sizeMB) || sizeMB <= 0) sizeMB = 50;
  if (sizeMB > 500) sizeMB = 500; // 单次最大限制 500MB，防止恶意消耗

  const totalBytes = Math.floor(sizeMB * 1024 * 1024);
  const CHUNK_SIZE = 64 * 1024; // 64KB 块

  const headers = {
    'Content-Type': 'application/octet-stream',
    'Content-Length': totalBytes.toString(),
    'Content-Disposition': `attachment; filename="speedtest_${sizeMB}MB.bin"`,
    'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
    'Pragma': 'no-cache',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
    'Access-Control-Allow-Headers': '*',
    'Timing-Allow-Origin': '*',
  };

  // HEAD 请求直接返回头部，零流开销
  if (request.method === 'HEAD') {
    return new Response(null, { status: 200, headers });
  }

  // 动态流式传输
  let bytesSent = 0;
  const chunk = new Uint8Array(CHUNK_SIZE);
  // 填充伪随机数据防止上游 HTTP 压缩
  for (let i = 0; i < CHUNK_SIZE; i += 4) {
    chunk[i] = (i & 0xff);
    chunk[i + 1] = ((i >> 8) & 0xff);
    chunk[i + 2] = ((i >> 16) & 0xff);
    chunk[i + 3] = ((i >> 24) & 0xff);
  }

  const stream = new ReadableStream({
    pull(controller) {
      if (bytesSent >= totalBytes) {
        controller.close();
        return;
      }

      const remaining = totalBytes - bytesSent;
      if (remaining >= CHUNK_SIZE) {
        controller.enqueue(chunk);
        bytesSent += CHUNK_SIZE;
      } else {
        controller.enqueue(chunk.subarray(0, remaining));
        bytesSent += remaining;
        controller.close();
      }
    }
  });

  return new Response(stream, { status: 200, headers });
}
