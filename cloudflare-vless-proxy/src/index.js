/**
 * Cloudflare Worker Main Entrypoint
 * VLESS Protocol over WebSocket + Residential Proxy Upstream + KV Admin Panel
 */

import { getConfig, verifyAdminAuth, hashPassword } from './config.js';
import { handleVlessWebSocket } from './vless.js';
import { handleAdmin } from './admin.js';
import { renderLandingPage } from './landing.js';
import { generateBase64Sub, generateClashFullProfile, generateSingboxFullProfile } from './sub.js';

export default {
  /**
   * Cloudflare Worker fetch 处理函数
   * @param {Request} request 
   * @param {object} env 
   * @param {object} ctx 
   * @returns {Promise<Response>}
   */
  async fetch(request, env, ctx) {
    try {
      // 1. 获取最新配置（优先从 KV 读取）
      const config = await getConfig(env);
      const url = new URL(request.url);
      const pathname = url.pathname;

      // 2. 路由 A：VLESS WebSocket 代理处理
      const isProxyPathMatch = pathname === config.proxyPath || pathname.startsWith(`${config.proxyPath}/`);
      const isWebSocketUpgrade = request.headers.get('Upgrade')?.toLowerCase() === 'websocket';

      if (isProxyPathMatch) {
        if (isWebSocketUpgrade) {
          return await handleVlessWebSocket(request, config);
        }
        // 如果是普通 HTTP GET 访问代理路径，返回伪装静态页面，防止被网络探测探针指纹识别
        return new Response(renderLandingPage(), {
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      }

      // 3. 路由 B：管理后台与 API (/admin)
      const isAdminPathMatch = pathname === config.adminPath || pathname.startsWith(`${config.adminPath}/`);
      if (isAdminPathMatch) {
        return await handleAdmin(request, env, url, config);
      }

      // 4. 路由 C：订阅聚合接口 (/sub)
      if (pathname === '/sub') {
        const token = url.searchParams.get('token') || '';
        const expectedToken = await hashPassword(config.adminPassword);
        if (token !== expectedToken) {
          return new Response(renderLandingPage(), {
            status: 200,
            headers: { 'Content-Type': 'text/html; charset=utf-8' },
          });
        }

        const format = (url.searchParams.get('format') || 'vless').toLowerCase();

        if (format === 'clash') {
          const yamlContent = generateClashFullProfile(config, url.host);
          return new Response(yamlContent, {
            headers: {
              'Content-Type': 'text/yaml; charset=utf-8',
              'Content-Disposition': 'attachment; filename="clash-config.yaml"',
              'Subscription-Userinfo': 'upload=0; download=0; total=1073741824000; expire=0',
              'Profile-Update-Interval': '24',
            },
          });
        }

        if (format === 'singbox') {
          const jsonContent = generateSingboxFullProfile(config, url.host);
          return new Response(jsonContent, {
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Content-Disposition': 'attachment; filename="singbox-config.json"',
              'Subscription-Userinfo': 'upload=0; download=0; total=1073741824000; expire=0',
              'Profile-Update-Interval': '24',
            },
          });
        }

        // 默认返回通用 Base64 订阅文本
        const subContent = generateBase64Sub(config, url.host);
        return new Response(subContent, {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Subscription-Userinfo': 'upload=0; download=0; total=1073741824000; expire=0',
            'Profile-Update-Interval': '24',
          },
        });
      }

      // 5. 路由 D：根路径 / 与其它未匹配路径返回汉武帝生平伪装静态落地页
      return new Response(renderLandingPage(), {
        status: 200,
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'public, max-age=3600',
        },
      });

    } catch (err) {
      console.error('Worker runtime error:', err);
      return new Response('Internal Server Error', { status: 500 });
    }
  },
};
