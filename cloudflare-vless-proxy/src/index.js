/**
 * Cloudflare Worker Main Entrypoint
 * VLESS Protocol over WebSocket + Dynamic Preferred IP + Subapi Subscription Conversion + KV Admin Panel
 */

import { getConfig, verifyAdminAuth, hashPassword, DEFAULT_CONFIG_URL, DEFAULT_SINGBOX_CONFIG_URL } from './config.js';
import { handleVlessWebSocket } from './vless.js';
import { handleAdmin } from './admin.js';
import { renderLandingPage } from './landing.js';
import { generateAllVlessNodes, generateBase64Sub, generateClashFullProfile, generateSingboxFullProfile, convertViaSubapi } from './sub.js';

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

      // 4. 路由 C：订阅聚合接口 (/sub, /clash, /singbox, /v2ray, /base64)
      const isSubRoute = pathname === '/sub' || pathname === '/clash' || pathname === '/singbox' || pathname === '/v2ray' || pathname === '/base64';

      if (isSubRoute) {
        const token = url.searchParams.get('token') || '';
        const expectedToken = await hashPassword(config.adminPassword);
        if (token !== expectedToken) {
          return new Response(renderLandingPage(), {
            status: 200,
            headers: { 'Content-Type': 'text/html; charset=utf-8' },
          });
        }

        const ua = (request.headers.get('User-Agent') || '').toLowerCase();
        const formatParam = (url.searchParams.get('format') || url.searchParams.get('target') || url.searchParams.get('flag') || '').toLowerCase();

        const isSingbox = pathname === '/singbox' ||
          formatParam === 'singbox' || formatParam === 'sing-box' ||
          (!formatParam && (ua.includes('sing-box') || ua.includes('singbox') || ua.includes('box')));

        const isClash = !isSingbox && (
          pathname === '/clash' ||
          formatParam === 'clash' || formatParam === 'mihomo' || formatParam === 'stash' ||
          (!formatParam && (ua.includes('clash') || ua.includes('stash') || ua.includes('mihomo') || ua.includes('verge') || ua.includes('meta')))
        );

        const isV2ray = pathname === '/v2ray' || pathname === '/base64' || formatParam === 'vless' || formatParam === 'base64' || formatParam === 'v2ray';

        // 统一构造给 subapi 转换使用的源订阅 URL
        const rawSubUrl = `${url.origin}/v2ray?token=${encodeURIComponent(token)}`;

        if (isSingbox) {
          const configTemplate = url.searchParams.get('config') || config.singboxConfigUrl || DEFAULT_SINGBOX_CONFIG_URL;
          let content = await convertViaSubapi(rawSubUrl, 'singbox', configTemplate, 3, config.subapiUrl);
          if (!content) {
            // 在线转换失败或超时时，使用本地动态优选节点生成完整配置兜底
            const nodes = await generateAllVlessNodes(config, url.host, { env });
            content = generateSingboxFullProfile(nodes, config, url.host);
          }
          return new Response(content, {
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Content-Disposition': 'attachment; filename="singbox-config.json"',
              'Subscription-Userinfo': 'upload=0; download=0; total=1073741824000; expire=0',
              'Profile-Update-Interval': '24',
            },
          });
        }

        if (isClash) {
          const configTemplate = url.searchParams.get('config') || config.configUrl || DEFAULT_CONFIG_URL;
          let content = await convertViaSubapi(rawSubUrl, 'clash', configTemplate, 3, config.subapiUrl);
          if (!content) {
            // 在线转换失败或超时时，使用本地动态优选节点生成完整配置兜底
            const nodes = await generateAllVlessNodes(config, url.host, { env });
            content = generateClashFullProfile(nodes, config, url.host);
          }
          return new Response(content, {
            headers: {
              'Content-Type': 'text/yaml; charset=utf-8',
              'Content-Disposition': 'attachment; filename="clash-config.yaml"',
              'Subscription-Userinfo': 'upload=0; download=0; total=1073741824000; expire=0',
              'Profile-Update-Interval': '24',
            },
          });
        }

        // 默认返回通用 Base64 订阅文本
        const nodes = await generateAllVlessNodes(config, url.host, { env });
        const subContent = generateBase64Sub(nodes, url.host);
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

