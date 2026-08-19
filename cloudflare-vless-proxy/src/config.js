/**
 * Cloudflare Worker Configuration & KV Manager
 */

export const DEFAULT_CONFIG_URL = 'https://raw.githubusercontent.com/JayYang1991/ACL4SSR/refs/heads/main/Clash/config/ACL4SSR_Online_Bespoke.ini';
export const DEFAULT_SINGBOX_CONFIG_URL = 'https://raw.githubusercontent.com/JayYang1991/ACL4SSR/refs/heads/main/sing-box/singbox-template.ini';
export const PREFERRED_SUB_URL = 'https://sub.19910417.xyz';
export const SUBAPI_URL = 'https://subapi.19910417.xyz';

export const DEFAULT_CONFIG = {
  uuid: 'd342d11e-d424-4583-b36e-524ab1f0afa4',
  proxyPath: '/data-ws',
  adminPath: '/admin',
  adminPassword: 'test1234!',
  apiToken: '',
  upstreamProxy: '',
  cleanIPs: 'cloudflare.com\ncf.090227.xyz\nvisa.cn\nicook.hk',
  nodeName: 'Edge-Gateway-Node',
  enableDirectFallback: true,
  configUrl: DEFAULT_CONFIG_URL,
  singboxConfigUrl: DEFAULT_SINGBOX_CONFIG_URL,
  preferredSubUrl: PREFERRED_SUB_URL,
  subapiUrl: SUBAPI_URL,
};

const KV_CONFIG_KEY = 'app_config';

/**
 * 获取当前系统的完整配置（优先从 KV 读取，无 KV 时回退到 env 环境变量或系统默认值）
 * 若 KV 中尚未初始化 API_TOKEN，则自动生成安全随机 Token 并持久化存储至 KV
 * @param {object} env Cloudflare Worker env
 * @returns {Promise<object>}
 */
export async function getConfig(env = {}) {
  const defaultApiToken = env.API_TOKEN || env.PUSH_TOKEN || env.DEFAULT_API_TOKEN || env.REST_TOKEN || '';
  
  const fallback = {
    uuid: env.DEFAULT_UUID || env.USER_ID || env.UUID || DEFAULT_CONFIG.uuid,
    proxyPath: env.DEFAULT_DATA_PATH || env.DEFAULT_WS_PATH || env.DEFAULT_PROXY_PATH || env.WS_PATH || env.PROXY_PATH || DEFAULT_CONFIG.proxyPath,
    adminPath: env.ADMIN_PATH || env.CONSOLE_PATH || DEFAULT_CONFIG.adminPath,
    adminPassword: env.ADMIN_PASSWORD || env.AUTH_SECRET || env.ADMIN_PASS || DEFAULT_CONFIG.adminPassword,
    apiToken: defaultApiToken || generateRandomApiToken(),
    upstreamProxy: env.DEFAULT_UPSTREAM_GATEWAY || env.DEFAULT_UPSTREAM_RELAY || env.DEFAULT_UPSTREAM_PROXY || env.UPSTREAM_GATEWAY || env.UPSTREAM_PROXY || DEFAULT_CONFIG.upstreamProxy,
    cleanIPs: (env.DEFAULT_CLEAN_IPS || env.CLEAN_IPS || env.CDN_IPS || DEFAULT_CONFIG.cleanIPs).replace(/,/g, '\n'),
    nodeName: env.DEFAULT_NODE_TAG || env.DEFAULT_NODE_NAME || env.NODE_TAG || env.NODE_NAME || DEFAULT_CONFIG.nodeName,
    enableDirectFallback: env.ENABLE_DIRECT_FALLBACK !== 'false',
    configUrl: DEFAULT_CONFIG.configUrl,
    singboxConfigUrl: DEFAULT_SINGBOX_CONFIG_URL,
    preferredSubUrl: PREFERRED_SUB_URL,
    subapiUrl: SUBAPI_URL,
  };

  // 标准化路径格式（确保以 / 开头，末尾不带 /）
  fallback.proxyPath = normalizePath(fallback.proxyPath);
  fallback.adminPath = normalizePath(fallback.adminPath);

  if (!env.CONFIG_KV) {
    return fallback;
  }

  try {
    const raw = await env.CONFIG_KV.get(KV_CONFIG_KEY, { type: 'json' });
    if (raw && typeof raw === 'object') {
      let currentToken = raw.apiToken || defaultApiToken;
      let needSave = false;

      // 如果 KV 中未存储 apiToken，自动生成并持久化写入 KV
      if (!currentToken) {
        currentToken = generateRandomApiToken();
        needSave = true;
      }

      const mergedConfig = {
        uuid: raw.uuid || fallback.uuid,
        proxyPath: normalizePath(raw.proxyPath || fallback.proxyPath),
        adminPath: normalizePath(raw.adminPath || fallback.adminPath),
        adminPassword: raw.adminPassword || fallback.adminPassword,
        apiToken: currentToken,
        upstreamProxy: raw.upstreamProxy !== undefined ? raw.upstreamProxy : fallback.upstreamProxy,
        cleanIPs: raw.cleanIPs !== undefined ? raw.cleanIPs : fallback.cleanIPs,
        nodeName: raw.nodeName || fallback.nodeName,
        enableDirectFallback: raw.enableDirectFallback !== undefined ? raw.enableDirectFallback : fallback.enableDirectFallback,
        configUrl: raw.configUrl || fallback.configUrl,
        singboxConfigUrl: raw.singboxConfigUrl || fallback.singboxConfigUrl,
        preferredSubUrl: raw.preferredSubUrl || fallback.preferredSubUrl,
        subapiUrl: raw.subapiUrl || fallback.subapiUrl,
      };

      if (needSave) {
        try {
          await env.CONFIG_KV.put(KV_CONFIG_KEY, JSON.stringify(mergedConfig, null, 2));
        } catch (saveErr) {
          console.error('Failed to auto-persist generated apiToken to KV:', saveErr);
        }
      }

      return mergedConfig;
    } else {
      // 首次初始化 KV，自动生成初始配置并持久化写入
      const initialConfig = {
        ...fallback,
        apiToken: defaultApiToken || generateRandomApiToken(),
      };
      try {
        await env.CONFIG_KV.put(KV_CONFIG_KEY, JSON.stringify(initialConfig, null, 2));
      } catch (initErr) {
        console.error('Failed to initialize config to KV:', initErr);
      }
      return initialConfig;
    }
  } catch (err) {
    console.error('Failed to read config from KV:', err);
  }

  return fallback;
}

/**
 * 保存或更新配置到 Cloudflare KV
 * @param {object} env 
 * @param {object} updates 
 */
export async function saveConfig(env, updates) {
  if (!env.CONFIG_KV) {
    throw new Error('Cloudflare KV 命名空间未绑定 (CONFIG_KV missing)，无法持久化保存。请在 wrangler.toml 中配置 KV binding。');
  }

  const current = await getConfig(env);
  const nextConfig = {
    ...current,
    ...updates,
  };

  if (nextConfig.proxyPath) {
    nextConfig.proxyPath = normalizePath(nextConfig.proxyPath);
  }
  if (nextConfig.adminPath) {
    nextConfig.adminPath = normalizePath(nextConfig.adminPath);
  }

  await env.CONFIG_KV.put(KV_CONFIG_KEY, JSON.stringify(nextConfig, null, 2));
  return nextConfig;
}

/**
 * 标准化 URL 路径
 */
export function normalizePath(p) {
  if (!p) return '/';
  let clean = p.trim();
  if (!clean.startsWith('/')) clean = '/' + clean;
  if (clean.length > 1 && clean.endsWith('/')) clean = clean.slice(0, -1);
  return clean;
}

/**
 * 校验用户 Token 是否匹配管理员密码
 */
export async function verifyAdminAuth(request, config) {
  const authHeader = request.headers.get('Authorization') || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
  const cookieHeader = request.headers.get('Cookie') || '';
  const match = cookieHeader.match(/admin_token=([^;]+)/);
  const cookieToken = match ? match[1] : '';

  const provided = token || cookieToken;
  if (!provided) return false;

  const expected = await hashPassword(config.adminPassword);
  return provided === expected;
}

/**
 * 校验专用于 REST API 代理推送修改的独立 Token
 * 优先校验单独配置的 apiToken，同时兼容管理员认证 Token
 * @param {Request} request 
 * @param {object} config 
 * @returns {Promise<boolean>}
 */
export async function verifyApiToken(request, config) {
  const url = new URL(request.url);
  const authHeader = request.headers.get('Authorization') || '';
  const bearerToken = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
  const xApiToken = request.headers.get('X-API-Token') || request.headers.get('Token') || request.headers.get('X-Token') || '';
  const queryToken = url.searchParams.get('token') || url.searchParams.get('api_token') || url.searchParams.get('key') || '';

  const provided = (bearerToken || xApiToken || queryToken).trim();
  if (!provided) return false;

  // 1. 校验单独生成的 apiToken
  const expectedApiToken = (config.apiToken || '').trim();
  if (expectedApiToken && provided === expectedApiToken) {
    return true;
  }

  // 2. 兼容管理员 Session / Token 鉴权
  const expectedAdminHash = await hashPassword(config.adminPassword);
  if (provided === expectedAdminHash) {
    return true;
  }

  return false;
}

/**
 * 生成安全的随机高强度 API Token
 * @returns {string}
 */
export function generateRandomApiToken() {
  const bytes = new Uint8Array(20);
  crypto.getRandomValues(bytes);
  const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  return `cf-push-${hex}`;
}

/**
 * 基于密码计算 SHA-256 Hash Token
 */
export async function hashPassword(password) {
  const enc = new TextEncoder();
  const data = enc.encode(`vless_admin_salt_${password}`);
  const hash = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hash));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}
