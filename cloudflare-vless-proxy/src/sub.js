/**
 * Subscription and Client Configuration Generator
 * Supports VLESS Base64, Clash Meta (Mihomo) full profile, and Sing-box full profile.
 */

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
    path: proxyPath,
  });

  return `vless://${uuid}@${host}:${port}?${params.toString()}#${encodeURIComponent(nodeName)}`;
}

/**
 * 根据优选 IP 列表生成全部 VLESS 节点列表
 */
export function generateAllVlessNodes(config, workerDomain) {
  const nodes = [];
  const rawIPs = (config.cleanIPs || '').split('\n').map(s => s.trim()).filter(Boolean);

  // 1. 默认官方 Worker 域名节点
  nodes.push({
    name: `${config.nodeName} (Worker直连)`,
    host: workerDomain,
    port: 443,
    url: generateVlessUrl({
      uuid: config.uuid,
      host: workerDomain,
      port: 443,
      workerDomain,
      proxyPath: config.proxyPath,
      nodeName: `${config.nodeName}-Direct`,
    }),
  });

  // 2. 优选 IP / 域名节点
  for (const ip of rawIPs) {
    let cleanHost = ip;
    let cleanPort = 443;
    if (ip.includes(':') && !ip.includes('[')) {
      const parts = ip.split(':');
      cleanHost = parts[0];
      cleanPort = parseInt(parts[1], 10) || 443;
    }

    nodes.push({
      name: `${config.nodeName} (${cleanHost})`,
      host: cleanHost,
      port: cleanPort,
      url: generateVlessUrl({
        uuid: config.uuid,
        host: cleanHost,
        port: cleanPort,
        workerDomain,
        proxyPath: config.proxyPath,
        nodeName: `${config.nodeName}-${cleanHost}`,
      }),
    });
  }

  return nodes;
}

/**
 * 生成标准 Base64 订阅内容 (适用于 V2rayN, Shadowrocket 等通用客户端)
 */
export function generateBase64Sub(config, workerDomain) {
  const nodes = generateAllVlessNodes(config, workerDomain);
  const rawUrls = nodes.map(n => n.url).join('\n');
  return btoa(unescape(encodeURIComponent(rawUrls)));
}

/**
 * 生成 Sing-box Client Outbound 节点数组 JSON 代码片段
 */
export function generateSingboxConfig(config, workerDomain) {
  const nodes = generateAllVlessNodes(config, workerDomain);
  const outbounds = nodes.map((node) => ({
    type: 'vless',
    tag: node.name,
    server: node.host,
    server_port: node.port,
    uuid: config.uuid,
    tls: {
      enabled: true,
      server_name: workerDomain,
      utls: {
        enabled: true,
        fingerprint: 'chrome',
      },
    },
    transport: {
      type: 'ws',
      path: config.proxyPath,
      headers: {
        Host: workerDomain,
      },
    },
  }));

  return JSON.stringify(outbounds, null, 2);
}

/**
 * 生成 Sing-box 客户端开箱即用完整配置文件 (Full Profile JSON)
 */
export function generateSingboxFullProfile(config, workerDomain) {
  const nodes = generateAllVlessNodes(config, workerDomain);
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
        server_name: workerDomain,
        utls: {
          enabled: true,
          fingerprint: 'chrome',
        },
      },
      transport: {
        type: 'ws',
        path: config.proxyPath,
        headers: {
          Host: workerDomain,
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
export function generateClashMetaConfig(config, workerDomain) {
  const nodes = generateAllVlessNodes(config, workerDomain);
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
    yamlLines.push(`    sni: ${workerDomain}`);
    yamlLines.push(`    client-fingerprint: chrome`);
    yamlLines.push(`    ws-opts:`);
    yamlLines.push(`      path: "${config.proxyPath}"`);
    yamlLines.push(`      headers:`);
    yamlLines.push(`        Host: ${workerDomain}`);
    yamlLines.push('');
  }

  return yamlLines.join('\n');
}

/**
 * 生成 Clash Meta (Mihomo) 客户端开箱即用完整配置文件 (Full Profile YAML)
 */
export function generateClashFullProfile(config, workerDomain) {
  const nodes = generateAllVlessNodes(config, workerDomain);
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
    sni: ${workerDomain}
    client-fingerprint: chrome
    ws-opts:
      path: "${config.proxyPath}"
      headers:
        Host: ${workerDomain}
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
