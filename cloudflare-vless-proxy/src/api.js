/**
 * REST API Endpoints for Dynamic Upstream Proxy Management
 * Authorized via dedicated API Token (Bearer Token / X-API-Token / Query Param)
 */

import { verifyApiToken, saveConfig } from './config.js';
import { parseProxyString, testUpstreamProxy } from './upstream.js';

/**
 * 处理上游代理 REST API 请求 (/api/upstream, /api/proxy, /api/upstream/test)
 * @param {Request} request 
 * @param {object} env 
 * @param {URL} url 
 * @param {object} config 
 * @returns {Promise<Response>}
 */
export async function handleRestApi(request, env, url, config) {
  const pathname = url.pathname.replace(/\/+$/, '');
  const method = request.method;

  // 处理 CORS 预检请求
  if (method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Token, Token',
      },
    });
  }

  // 1. 独立 API Token 鉴权校验
  const isAuthed = await verifyApiToken(request, config);
  if (!isAuthed) {
    return jsonResponse({
      success: false,
      error: 'Unauthorized: Invalid or missing API Token. Please provide token via Authorization: Bearer <token>, X-API-Token header, or ?token=<token> parameter.',
      tip: '可在 /admin 管理控制台中查看或生成专属 REST API Token。'
    }, 401);
  }

  // 2. 路由：POST /api/upstream/test 或 POST /api/proxy/test (在线测试代理)
  if ((pathname === '/api/upstream/test' || pathname === '/api/proxy/test') && method === 'POST') {
    return handleTestProxyApi(request, config);
  }

  // 3. 路由：GET /api/upstream 或 GET /api/proxy (查询当前代理状态)
  if ((pathname === '/api/upstream' || pathname === '/api/proxy') && method === 'GET') {
    const parsed = parseProxyString(config.upstreamProxy);
    return jsonResponse({
      success: true,
      upstreamProxy: config.upstreamProxy,
      parsed,
      enableDirectFallback: config.enableDirectFallback,
      nodeName: config.nodeName,
    });
  }

  // 4. 路由：POST / PUT /api/upstream 或 POST / PUT /api/proxy (修改并推送新代理)
  if ((pathname === '/api/upstream' || pathname === '/api/proxy') && (method === 'POST' || method === 'PUT')) {
    return handleUpdateProxyApi(request, env, config);
  }

  return jsonResponse({ success: false, error: 'Endpoint Not Found' }, 404);
}

/**
 * 处理代理修改推送
 */
async function handleUpdateProxyApi(request, env, config) {
  let newProxy = '';
  let enableDirectFallback = config.enableDirectFallback;
  let shouldTest = false;

  const contentType = request.headers.get('Content-Type') || '';

  try {
    if (contentType.includes('application/json')) {
      const body = await request.json();
      newProxy = body.upstreamProxy !== undefined ? body.upstreamProxy :
        (body.proxy !== undefined ? body.proxy :
          (body.upstream !== undefined ? body.upstream :
            (body.gateway !== undefined ? body.gateway : config.upstreamProxy)));

      if (body.enableDirectFallback !== undefined) {
        enableDirectFallback = Boolean(body.enableDirectFallback);
      } else if (body.enableFallback !== undefined) {
        enableDirectFallback = Boolean(body.enableFallback);
      } else if (body.fallback !== undefined) {
        enableDirectFallback = Boolean(body.fallback);
      }

      if (body.test === true || body.runTest === true) {
        shouldTest = true;
      }
    } else {
      // 纯文本或其他格式，直接将 body 文本作为代理字符串
      const text = await request.text();
      newProxy = text ? text.trim() : config.upstreamProxy;
    }
  } catch (err) {
    return jsonResponse({ success: false, error: `Invalid request payload: ${err.message}` }, 400);
  }

  if (typeof newProxy !== 'string') {
    return jsonResponse({ success: false, error: 'Invalid upstreamProxy value. Must be a string.' }, 400);
  }

  const trimmedProxy = newProxy.trim();
  let parsed = null;

  // 如果非空，校验代理格式
  if (trimmedProxy) {
    parsed = parseProxyString(trimmedProxy);
    if (!parsed) {
      return jsonResponse({
        success: false,
        error: '无法解析上游代理格式。支持 OpenVPN (原生 .ovpn 文本/Base64、openvpn:// 或 ovpn://)、SOCKS5 (socks5://...)、HTTP (http://...)、host:port 等格式。',
        raw: trimmedProxy,
      }, 400);
    }
  }

  // 若开启了 test 选项，执行在线握手测速
  let testResult = null;
  if (shouldTest && trimmedProxy) {
    testResult = await testUpstreamProxy(trimmedProxy);
  }

  // 持久化更新至 Cloudflare KV
  const updates = {
    upstreamProxy: trimmedProxy,
    enableDirectFallback,
  };

  try {
    const nextConfig = await saveConfig(env, updates);
    return jsonResponse({
      success: true,
      message: '上游住宅代理已成功更新并持久化至 KV！',
      upstreamProxy: nextConfig.upstreamProxy,
      parsed,
      enableDirectFallback: nextConfig.enableDirectFallback,
      testResult,
      updatedAt: new Date().toISOString(),
    });
  } catch (err) {
    return jsonResponse({
      success: false,
      error: `保存配置至 KV 失败: ${err.message}`,
      fallbackConfig: updates,
    }, 500);
  }
}

/**
 * 处理代理测试接口
 */
async function handleTestProxyApi(request, config) {
  let targetProxy = config.upstreamProxy;
  const contentType = request.headers.get('Content-Type') || '';

  try {
    if (contentType.includes('application/json')) {
      const body = await request.json();
      if (body.upstreamProxy) targetProxy = body.upstreamProxy;
      else if (body.proxy) targetProxy = body.proxy;
    } else {
      const text = await request.text();
      if (text.trim()) targetProxy = text.trim();
    }
  } catch (_) {}

  if (!targetProxy) {
    return jsonResponse({
      success: false,
      message: '未指定需测试的代理，且系统当前未配置上游代理。'
    }, 400);
  }

  const result = await testUpstreamProxy(targetProxy);
  return jsonResponse(result, result.success ? 200 : 502);
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Token, Token',
    },
  });
}
