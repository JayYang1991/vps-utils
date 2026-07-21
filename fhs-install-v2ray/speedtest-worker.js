/**
 * Cloudflare Workers Speed Test (Backend Only)
 * Optimized for CloudflareSpeedTest (cfst) and other CLI tools.
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Endpoint for download test
    if (url.pathname === '/__down' || url.pathname === '/download') {
      let size;
      const bytesParam = url.searchParams.get('bytes');
      if (bytesParam) {
        size = parseInt(bytesParam);
      } else {
        size = parseInt(url.searchParams.get('size') || '100') * 1024 * 1024; // Default 100MB
      }
      
      const chunkSize = 64 * 1024; // 64KB chunks (crypto.getRandomValues limit)
      const chunk = new Uint8Array(chunkSize);
      crypto.getRandomValues(chunk);

      let bytesSent = 0;
      const stream = new ReadableStream({
        pull(controller) {
          const remaining = size - bytesSent;
          if (remaining > 0) {
            const toSend = Math.min(remaining, chunkSize);
            controller.enqueue(toSend === chunkSize ? chunk : chunk.slice(0, toSend));
            bytesSent += toSend;
          } else {
            controller.close();
          }
        }
      });

      return new Response(stream, {
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': size.toString(),
          'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
          'Access-Control-Allow-Origin': '*',
          'cf-cache-status': 'MISS',
        }
      });
    }

    // Endpoint for latency test (Google style)
    if (url.pathname === '/generate_204' || url.pathname === '/204') {
      return new Response(null, {
        status: 204,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
        }
      });
    }

    // Endpoint for CloudflareTrace compatibility
    if (url.pathname === '/cdn-cgi/trace' || url.pathname === '/') {
      const trace = [
        `fl=${request.cf?.asOrganization || 'Cloudflare'}`,
        `h=${url.hostname}`,
        `ip=${request.headers.get('cf-connecting-ip')}`,
        `ts=${(Date.now() / 1000).toFixed(3)}`,
        `visit_scheme=${url.protocol.replace(':', '')}`,
        `uag=${request.headers.get('user-agent')}`,
        `colo=${request.cf?.colo || 'UNK'}`,
        `sliver=none`,
        `http=${request.cf?.httpProtocol || 'http/2'}`,
        `loc=${request.headers.get('cf-ipcountry') || 'XX'}`,
        `tls=${request.cf?.tlsVersion || 'TLSv1.3'}`,
        `sni=plaintext`,
        `warp=off`,
        `gateway=off`,
        `client_ip=${request.headers.get('cf-connecting-ip')}`,
        `user_agent=${request.headers.get('user-agent')}`,
      ].join('\n') + '\n';
      
      return new Response(trace, {
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'Access-Control-Allow-Origin': '*',
        }
      });
    }

    // Endpoint for upload test
    if (url.pathname === '/__up') {
      await request.arrayBuffer(); // Consume the stream
      return new Response('ok', {
        headers: {
          'Access-Control-Allow-Origin': '*',
        }
      });
    }

    return new Response('Not Found', { status: 404 });
  }
};
