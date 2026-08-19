/**
 * Subscription and Client Configuration Generator
 * Supports dynamic preferred IP fetching from https://sub.19910417.xyz
 * and online subscription conversion via https://subapi.19910417.xyz
 */

import { DEFAULT_CONFIG_URL, DEFAULT_SINGBOX_CONFIG_URL, PREFERRED_SUB_URL, SUBAPI_URL } from './config.js';

export { DEFAULT_CONFIG_URL, DEFAULT_SINGBOX_CONFIG_URL, PREFERRED_SUB_URL, SUBAPI_URL };
export const REMOTE_SUBCONFIG_URL = 'https://raw.githubusercontent.com/JayYang1991/edgetunnel/main/SUBCONFIG.json';
export const USER_AGENT = 'v2rayN/edgetunnel (https://github.com/cmliu/edgetunnel)';

let _preferredNodesCache = null;
let _preferredNodesLastFetch = 0;
const PREFERRED_CACHE_TTL = 600 * 1000; // 10 分钟内存缓存

let _cachedSubconfigs = [];

/**
 * 清除优选 IP 内存缓存
 */
export function clearPreferredNodesCache() {
  _preferredNodesCache = null;
  _preferredNodesLastFetch = 0;
}

/**
 * 生成 VLESS 单节点连接 URL
 */
export function generateVlessUrl({ uuid, host, port = 443, workerDomain, proxyPath, nodeName }) {
  const params = new URLSearchParams({
    encryption: 'none',
    security: 'tls',
    sni: workerDomain,
    fp: 'chrome',
    type: 'ws',
    host: workerDomain,
    path: proxyPath || '/',
  });

  return `vless://${uuid}@${host}:${port}?${params.toString()}#${encodeURIComponent(nodeName)}`;
}

/**
 * 解析 sub.19910417.xyz 返回的 Base64/文本订阅内容并构造 VLESS 节点列表
 * @param {string} rawData 
 * @param {object} config 
 * @param {string} workerDomain 
 * @returns {Array<object>}
 */
export function parseVlessSubResponse(rawData, config, workerDomain) {
  if (!rawData || typeof rawData !== 'string') return [];

  let decoded = rawData;
  try {
    const cleaned = rawData.trim();
    if (!cleaned.includes('vless://') && cleaned.length > 20) {
      decoded = atob(cleaned.replace(/\s/g, ''));
    }
  } catch (_) {
    decoded = rawData;
  }

  const nodes = [];
  const lines = decoded.split(/\r?\n/);
  let idx = 1;

  for (let line of lines) {
    line = line.trim();
    if (!line.startsWith('vless://')) continue;

    try {
      const withoutScheme = line.slice(8);
      const hashIdx = withoutScheme.indexOf('#');
      let mainPart = hashIdx !== -1 ? withoutScheme.slice(0, hashIdx) : withoutScheme;
      let rawTag = hashIdx !== -1 ? withoutScheme.slice(hashIdx + 1) : '';

      const tag = rawTag ? decodeURIComponent(rawTag) : '';
      if (tag.includes('不再支持旧版') || tag.includes('更新至最新版本')) continue;

      const atIdx = mainPart.indexOf('@');
      if (atIdx === -1) continue;
      const ipPortAndQuery = mainPart.slice(atIdx + 1);

      const qIdx = ipPortAndQuery.indexOf('?');
      const ipPort = qIdx !== -1 ? ipPortAndQuery.slice(0, qIdx) : ipPortAndQuery;

      let ip = ipPort;
      let port = 443;
      if (ipPort.includes(':') && !ipPort.includes('[')) {
        const parts = ipPort.split(':');
        ip = parts[0];
        port = parseInt(parts[1], 10) || 443;
      }

      if (['example.com', '127.0.0.1', 'localhost'].includes(ip)) continue;

      const cleanTag = tag.replace(/^#+/, '').trim() || `${ip}`;
      const prefix = config.nodeName || 'CF';
      const nodeName = `${prefix}-${cleanTag}-${String(idx).padStart(2, '0')}`;

      const vlessUrl = generateVlessUrl({
        uuid: config.uuid,
        host: ip,
        port,
        workerDomain,
        proxyPath: config.proxyPath,
        nodeName,
      });

      nodes.push({
        name: nodeName,
        host: ip,
        port,
        url: vlessUrl,
        category: 'preferred',
      });
      idx++;
    } catch (e) {
      console.warn('Error parsing VLESS line from sub response:', e);
    }
  }

  return nodes;
}

/**
 * 从 https://sub.19910417.xyz 动态获取 Cloudflare 优选 IP 节点列表 (带 10 分钟缓存与超时控制)
 * @param {object} config 
 * @param {string} workerDomain 
 * @param {boolean} forceRefresh 
 * @param {object} env 
 * @returns {Promise<Array<object>>}
 */
export async function fetchPreferredNodes(config, workerDomain, forceRefresh = false, env = null) {
  const now = Date.now();
  if (!forceRefresh && _preferredNodesCache && (now - _preferredNodesLastFetch < PREFERRED_CACHE_TTL)) {
    return _preferredNodesCache;
  }

  const subBase = (config.preferredSubUrl || PREFERRED_SUB_URL).replace(/\/+$/, '');
  const url = `${subBase}/sub?host=${encodeURIComponent(workerDomain)}&uuid=${encodeURIComponent(config.uuid)}`;

  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 6000);

    const resp = await fetch(url, {
      headers: {
        'User-Agent': USER_AGENT,
      },
      signal: controller.signal,
    });
    clearTimeout(timeoutId);

    if (resp.ok) {
      const data = await resp.text();
      const nodes = parseVlessSubResponse(data, config, workerDomain);
      if (nodes.length > 0) {
        _preferredNodesCache = nodes;
        _preferredNodesLastFetch = now;
        return nodes;
      }
    }
  } catch (err) {
    console.error('Error fetching preferred nodes from sub.19910417.xyz:', err.message || err);
  }

  if (_preferredNodesCache && _preferredNodesCache.length > 0) {
    return _preferredNodesCache;
  }

  return [];
}

/**
 * 同步生成基础/回退 VLESS 节点列表 (包括直连节点与 cleanIPs 兜底节点)
 * @param {object} config 
 * @param {string} workerDomain 
 * @returns {Array<object>}
 */
export function generateAllVlessNodesSync(config, workerDomain) {
  const nodes = [];

  // 1. 默认官方 Worker 域名节点
  const directName = `${config.nodeName || 'CF'}-Direct`;
  nodes.push({
    name: directName,
    host: workerDomain,
    port: 443,
    url: generateVlessUrl({
      uuid: config.uuid,
      host: workerDomain,
      port: 443,
      workerDomain,
      proxyPath: config.proxyPath,
      nodeName: directName,
    }),
    category: 'direct',
  });

  // 2. 优选 IP / 域名兜底列表
  const rawIPs = (config.cleanIPs || '').split('\n').map(s => s.trim()).filter(Boolean);
  let idx = 1;
  for (const ip of rawIPs) {
    let cleanHost = ip;
    let cleanPort = 443;
    if (ip.includes(':') && !ip.includes('[')) {
      const parts = ip.split(':');
      cleanHost = parts[0];
      cleanPort = parseInt(parts[1], 10) || 443;
    }

    const nodeName = `${config.nodeName || 'CF'}-${cleanHost}-${String(idx).padStart(2, '0')}`;
    nodes.push({
      name: nodeName,
      host: cleanHost,
      port: cleanPort,
      url: generateVlessUrl({
        uuid: config.uuid,
        host: cleanHost,
        port: cleanPort,
        workerDomain,
        proxyPath: config.proxyPath,
        nodeName,
      }),
      category: 'preferred',
    });
    idx++;
  }

  return nodes;
}

/**
 * 异步获取所有 VLESS 节点 (Worker 直连节点 + 动态从 sub.19910417.xyz 获取的优选 IP 节点 + cleanIPs 兜底)
 * @param {object} config 
 * @param {string} workerDomain 
 * @param {object} options 
 * @returns {Promise<Array<object>>}
 */
export async function generateAllVlessNodes(config, workerDomain, options = {}) {
  const { forceRefresh = false, env = null } = options;
  const nodes = [];

  // 1. 默认官方 Worker 直连节点
  const directName = `${config.nodeName || 'CF'}-Direct`;
  nodes.push({
    name: directName,
    host: workerDomain,
    port: 443,
    url: generateVlessUrl({
      uuid: config.uuid,
      host: workerDomain,
      port: 443,
      workerDomain,
      proxyPath: config.proxyPath,
      nodeName: directName,
    }),
    category: 'direct',
  });

  // 2. 动态从 sub.19910417.xyz 获取优选节点
  const preferredNodes = await fetchPreferredNodes(config, workerDomain, forceRefresh, env);
  if (preferredNodes && preferredNodes.length > 0) {
    nodes.push(...preferredNodes);
  } else {
    // 3. 动态获取失败时使用 cleanIPs 进行本地节点兜底
    const rawIPs = (config.cleanIPs || '').split('\n').map(s => s.trim()).filter(Boolean);
    let idx = 1;
    for (const ip of rawIPs) {
      let cleanHost = ip;
      let cleanPort = 443;
      if (ip.includes(':') && !ip.includes('[')) {
        const parts = ip.split(':');
        cleanHost = parts[0];
        cleanPort = parseInt(parts[1], 10) || 443;
      }

      const nodeName = `${config.nodeName || 'CF'}-${cleanHost}-${String(idx).padStart(2, '0')}`;
      nodes.push({
        name: nodeName,
        host: cleanHost,
        port: cleanPort,
        url: generateVlessUrl({
          uuid: config.uuid,
          host: cleanHost,
          port: cleanPort,
          workerDomain,
          proxyPath: config.proxyPath,
          nodeName,
        }),
        category: 'preferred',
      });
      idx++;
    }
  }

  return nodes;
}

/**
 * 调用 https://subapi.19910417.xyz 在线订阅转换接口生成 Clash / Singbox 配置文件
 * @param {string} subUrl 待转换的原始订阅 URL
 * @param {string} target 目标类型 'clash' | 'singbox'
 * @param {string} configUrl 规则策略配置文件 URL (如 ACL4SSR 或自定义 ini)
 * @param {number} maxRetries 重试次数
 * @param {string} subapiUrl 自定义 subapi 转换服务 URL
 * @returns {Promise<string>}
 */
export async function convertViaSubapi(subUrl, target = 'clash', configUrl = '', maxRetries = 3, subapiUrl = '') {
  if (!subUrl) {
    console.warn(`Subapi 转换跳过: 传入的 subUrl 为空 (target=${target})`);
    return '';
  }

  const isSingbox = target.toLowerCase().includes('singbox') || target.toLowerCase().includes('sing-box');
  const subapiTarget = isSingbox ? 'singbox' : 'clash';
  const encodedUrl = encodeURIComponent(subUrl);

  let cfg = configUrl;
  if (!cfg) {
    cfg = isSingbox ? DEFAULT_SINGBOX_CONFIG_URL : DEFAULT_CONFIG_URL;
  }

  const subapiBase = (subapiUrl || SUBAPI_URL).replace(/\/+$/, '');
  const apiUrl = `${subapiBase}/sub?target=${subapiTarget}&url=${encodedUrl}&filter_local=false&config=${encodeURIComponent(cfg)}`;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    const timeoutMs = (attempt + 1) * 4000; // 8s, 12s, 16s
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const resp = await fetch(apiUrl, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      if (resp.ok) {
        const content = await resp.text();
        const isValid = ['proxies', 'outbounds', 'outbound', 'port', 'inbounds'].some(k => content.includes(k));
        if (content.length > 100 && isValid) {
          if (!isSingbox) {
            return cleanClashDirectOnlyGroups(content);
          }
          return content;
        }
      }
    } catch (err) {
      clearTimeout(timeoutId);
      console.warn(`Subapi 转换尝试 ${attempt}/${maxRetries} 异常:`, err.message || err);
    }
  }

  return '';
}

/**
 * 清理 Clash 配置中只有 DIRECT 的 select 和 url-test 节点分组，并更新关联引用
 * @param {string} yaml Clash 完整配置 YAML 文本
 * @returns {string} 清理后的 YAML 文本
 */
export function cleanClashDirectOnlyGroups(yaml) {
  if (!yaml || typeof yaml !== 'string') return yaml;

  const lines = yaml.split(/\r?\n/);
  const pgStartIdx = lines.findIndex(l => /^proxy-groups\s*:/.test(l));
  if (pgStartIdx === -1) return yaml;

  let pgEndIdx = lines.findIndex((l, idx) => idx > pgStartIdx && /^[a-zA-Z0-9_-]+\s*:/.test(l));
  if (pgEndIdx === -1) pgEndIdx = lines.length;

  const headerLines = lines.slice(0, pgStartIdx + 1);
  const pgLines = lines.slice(pgStartIdx + 1, pgEndIdx);
  const footerLines = lines.slice(pgEndIdx);

  const groups = [];
  let currentGroup = null;
  let inProxies = false;

  for (let i = 0; i < pgLines.length; i++) {
    const line = pgLines[i];
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const groupItemMatch = line.match(/^\s*-\s+name:\s*(.+)$/);
    if (groupItemMatch) {
      currentGroup = {
        name: groupItemMatch[1].trim().replace(/^['\"]|['\"]$/g, ''),
        fields: [],
        proxies: [],
        type: 'select',
      };
      groups.push(currentGroup);
      inProxies = false;
      continue;
    }

    if (!currentGroup) continue;

    const typeMatch = line.match(/^\s*type:\s*(.+)$/);
    if (typeMatch) {
      currentGroup.type = typeMatch[1].trim().toLowerCase().replace(/^['\"]|['\"]$/g, '');
      currentGroup.fields.push(line);
      inProxies = false;
      continue;
    }

    if (/^\s*proxies\s*:/.test(line)) {
      inProxies = true;
      continue;
    }

    if (inProxies) {
      const proxyItemMatch = line.match(/^\s*-\s+(.+)$/);
      if (proxyItemMatch) {
        const pName = proxyItemMatch[1].trim().replace(/^['\"]|['\"]$/g, '');
        currentGroup.proxies.push(pName);
        continue;
      } else {
        inProxies = false;
      }
    }

    currentGroup.fields.push(line);
  }

  let removedAny = true;
  const removedNames = new Set();

  while (removedAny) {
    removedAny = false;
    for (let i = groups.length - 1; i >= 0; i--) {
      const g = groups[i];
      const isTargetType = ['select', 'url-test', 'urltest', 'fallback', 'load-balance'].includes(g.type);
      const isOnlyDirect = g.proxies.length === 0 || g.proxies.every(p => p.toUpperCase() === 'DIRECT');

      if (isTargetType && isOnlyDirect) {
        removedNames.add(g.name);
        groups.splice(i, 1);
        removedAny = true;
      }
    }

    if (removedAny) {
      for (const g of groups) {
        g.proxies = g.proxies.filter(p => !removedNames.has(p));
      }
    }
  }

  const newPgLines = [];
  for (const g of groups) {
    newPgLines.push(`  - name: ${g.name}`);
    for (const f of g.fields) {
      newPgLines.push(f);
    }
    newPgLines.push('    proxies:');
    if (g.proxies.length > 0) {
      for (const p of g.proxies) {
        newPgLines.push(`      - ${p}`);
      }
    } else {
      newPgLines.push('      - DIRECT');
    }
  }

  const newFooterLines = footerLines.map(line => {
    let modifiedLine = line;
    for (const rName of removedNames) {
      if (modifiedLine.includes(rName)) {
        const parts = modifiedLine.split(',');
        if (parts.length === 2 && parts[1].trim() === rName) {
          parts[1] = 'DIRECT';
          modifiedLine = parts.join(',');
        } else if (parts.length >= 3 && parts[2].trim() === rName) {
          parts[2] = 'DIRECT';
          modifiedLine = parts.join(',');
        }
      }
    }
    return modifiedLine;
  });

  return [...headerLines, ...newPgLines, ...newFooterLines].join('\n');
}

/**
 * 获取远程 SUBCONFIG 规则列表 (用于前端下拉选择)
 * @returns {Promise<Array<object>>}
 */
export async function fetchSubconfigs() {
  if (_cachedSubconfigs && _cachedSubconfigs.length > 0) {
    return _cachedSubconfigs;
  }
  try {
    const resp = await fetch(REMOTE_SUBCONFIG_URL, {
      headers: { 'User-Agent': 'Mozilla/5.0' },
    });
    if (resp.ok) {
      const data = await resp.json();
      if (Array.isArray(data)) {
        _cachedSubconfigs = data;
        return data;
      }
    }
  } catch (e) {
    console.error('Error fetching remote SUBCONFIG.json:', e);
  }
  return _cachedSubconfigs;
}

/**
 * 规范化节点输入 (支持传入节点数组或 (config, workerDomain) 组合)
 */
function resolveNodes(nodesOrConfig, workerDomain) {
  if (Array.isArray(nodesOrConfig)) {
    return nodesOrConfig;
  }
  if (nodesOrConfig && typeof nodesOrConfig === 'object' && workerDomain) {
    return generateAllVlessNodesSync(nodesOrConfig, workerDomain);
  }
  return [];
}

/**
 * 生成标准 Base64 订阅内容 (适用于 V2rayN, Shadowrocket 等通用客户端)
 */
export function generateBase64Sub(nodesOrConfig, workerDomain) {
  const nodes = resolveNodes(nodesOrConfig, workerDomain);
  const rawUrls = nodes.map(n => n.url).join('\n');
  return btoa(unescape(encodeURIComponent(rawUrls)));
}

/**
 * 生成 Sing-box Client Outbound 节点数组 JSON 代码片段
 */
export function generateSingboxConfig(nodesOrConfig, workerDomainOrConfig, maybeWorkerDomain) {
  let nodes = [];
  let workerDomain = '';
  let config = {};

  if (Array.isArray(nodesOrConfig)) {
    nodes = nodesOrConfig;
    config = workerDomainOrConfig || {};
    workerDomain = maybeWorkerDomain || '';
  } else {
    config = nodesOrConfig || {};
    workerDomain = workerDomainOrConfig || '';
    nodes = generateAllVlessNodesSync(config, workerDomain);
  }

  const outbounds = nodes.map((node) => ({
    type: 'vless',
    tag: node.name,
    server: node.host,
    server_port: node.port,
    uuid: config.uuid,
    tls: {
      enabled: true,
      server_name: workerDomain || node.host,
      utls: {
        enabled: true,
        fingerprint: 'chrome',
      },
    },
    transport: {
      type: 'ws',
      path: config.proxyPath || '/',
      headers: {
        Host: workerDomain || node.host,
      },
    },
  }));

  return JSON.stringify(outbounds, null, 2);
}

/**
 * 生成 Sing-box 客户端开箱即用完整配置文件 (本地兜底 Profile JSON)
 */
export function generateSingboxFullProfile(nodesOrConfig, workerDomainOrConfig, maybeWorkerDomain) {
  let nodes = [];
  let workerDomain = '';
  let config = {};

  if (Array.isArray(nodesOrConfig)) {
    nodes = nodesOrConfig;
    config = workerDomainOrConfig || {};
    workerDomain = maybeWorkerDomain || '';
  } else {
    config = nodesOrConfig || {};
    workerDomain = workerDomainOrConfig || '';
    nodes = generateAllVlessNodesSync(config, workerDomain);
  }

  const nodeTags = nodes.map(n => n.name);

  const outbounds = [
    {
      type: 'selector',
      tag: '🚀 节点选择',
      outbounds: ['⚡ 自动测优', ...nodeTags, 'DIRECT'],
      default: '⚡ 自动测优',
    },
    {
      type: 'urltest',
      tag: '⚡ 自动测优',
      outbounds: [...nodeTags],
      url: 'https://www.gstatic.com/generate_204',
      interval: '3m',
      tolerance: 50,
    },
    ...nodes.map((node) => ({
      type: 'vless',
      tag: node.name,
      server: node.host,
      server_port: node.port,
      uuid: config.uuid,
      tls: {
        enabled: true,
        server_name: workerDomain || node.host,
        utls: {
          enabled: true,
          fingerprint: 'chrome',
        },
      },
      transport: {
        type: 'ws',
        path: config.proxyPath || '/',
        headers: {
          Host: workerDomain || node.host,
        },
      },
    })),
    {
      type: 'direct',
      tag: 'DIRECT',
    },
    {
      type: 'block',
      tag: 'REJECT',
    },
    {
      type: 'dns',
      tag: 'dns-out',
    },
  ];

  const profile = {
    log: {
      level: 'info',
      timestamp: true,
    },
    dns: {
      servers: [
        {
          tag: 'dns-remote',
          address: 'https://1.1.1.1/dns-query',
          detour: '🚀 节点选择',
        },
        {
          tag: 'dns-local',
          address: '223.5.5.5',
          detour: 'DIRECT',
        },
      ],
      rules: [
        {
          outbound: 'any',
          server: 'dns-local',
        },
      ],
      strategy: 'prefer_ipv4',
    },
    inbounds: [
      {
        type: 'mixed',
        tag: 'mixed-in',
        listen: '127.0.0.1',
        listen_port: 2080,
      },
    ],
    outbounds,
    route: {
      rules: [
        {
          protocol: 'dns',
          outbound: 'dns-out',
        },
        {
          clash_mode: 'Global',
          outbound: '🚀 节点选择',
        },
        {
          clash_mode: 'Direct',
          outbound: 'DIRECT',
        },
      ],
      auto_detect_interface: true,
    },
  };

  return JSON.stringify(profile, null, 2);
}

/**
 * 生成 Clash Meta (Mihomo) Outbound 节点 YAML 代码片段
 */
export function generateClashMetaConfig(nodesOrConfig, workerDomainOrConfig, maybeWorkerDomain) {
  let nodes = [];
  let workerDomain = '';
  let config = {};

  if (Array.isArray(nodesOrConfig)) {
    nodes = nodesOrConfig;
    config = workerDomainOrConfig || {};
    workerDomain = maybeWorkerDomain || '';
  } else {
    config = nodesOrConfig || {};
    workerDomain = workerDomainOrConfig || '';
    nodes = generateAllVlessNodesSync(config, workerDomain);
  }

  const yamlLines = ['proxies:'];

  for (const node of nodes) {
    yamlLines.push(`  - name: "${node.name}"`);
    yamlLines.push(`    type: vless`);
    yamlLines.push(`    server: ${node.host}`);
    yamlLines.push(`    port: ${node.port}`);
    yamlLines.push(`    uuid: ${config.uuid}`);
    yamlLines.push(`    network: ws`);
    yamlLines.push(`    tls: true`);
    yamlLines.push(`    udp: true`);
    yamlLines.push(`    sni: ${workerDomain || node.host}`);
    yamlLines.push(`    client-fingerprint: chrome`);
    yamlLines.push(`    ws-opts:`);
    yamlLines.push(`      path: "${config.proxyPath || '/'}"`);
    yamlLines.push(`      headers:`);
    yamlLines.push(`        Host: ${workerDomain || node.host}`);
    yamlLines.push('');
  }

  return yamlLines.join('\n');
}

/**
 * 生成 Clash Meta (Mihomo) 客户端开箱即用完整配置文件 (本地兜底 Profile YAML)
 */
export function generateClashFullProfile(nodesOrConfig, workerDomainOrConfig, maybeWorkerDomain) {
  let nodes = [];
  let workerDomain = '';
  let config = {};

  if (Array.isArray(nodesOrConfig)) {
    nodes = nodesOrConfig;
    config = workerDomainOrConfig || {};
    workerDomain = maybeWorkerDomain || '';
  } else {
    config = nodesOrConfig || {};
    workerDomain = workerDomainOrConfig || '';
    nodes = generateAllVlessNodesSync(config, workerDomain);
  }

  const nodeNames = nodes.map(n => `"${n.name}"`);

  let yaml = `port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
unified-delay: true

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  default-nameserver: [223.5.5.5, 119.29.29.29]
  nameserver: [https://1.1.1.1/dns-query, https://8.8.8.8/dns-query]

proxies:
`;

  for (const node of nodes) {
    yaml += `  - name: "${node.name}"
    type: vless
    server: ${node.host}
    port: ${node.port}
    uuid: ${config.uuid}
    network: ws
    tls: true
    udp: true
    sni: ${workerDomain || node.host}
    client-fingerprint: chrome
    ws-opts:
      path: "${config.proxyPath || '/'}"
      headers:
        Host: ${workerDomain || node.host}
`;
  }

  yaml += `
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "⚡ 自动优选"
      ${nodeNames.map(n => `- ${n}`).join('\n      ')}
      - "DIRECT"

  - name: "⚡ 自动优选"
    type: url-test
    proxies:
      ${nodeNames.map(n => `- ${n}`).join('\n      ')}
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50

rules:
  - GEOIP,LAN,DIRECT
  - MATCH,🚀 节点选择
`;

  return yaml;
}

