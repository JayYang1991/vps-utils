import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseProxyString } from '../src/upstream.js';
import { parseVlessHeader, bytesToUUID } from '../src/vless.js';
import { generateVlessUrl, generateAllVlessNodes, generateSingboxConfig, generateSingboxFullProfile, generateBase64Sub } from '../src/sub.js';
import { hashPassword, normalizePath } from '../src/config.js';

describe('Upstream Proxy String Parser', () => {
  it('should parse standard socks5:// url with user/pass', () => {
    const res = parseProxyString('socks5://alice:secret123@proxy.iproyal.com:12321');
    assert.deepEqual(res, {
      protocol: 'socks5',
      host: 'proxy.iproyal.com',
      port: 12321,
      username: 'alice',
      password: 'secret123'
    });
  });

  it('should parse http:// url with user/pass', () => {
    const res = parseProxyString('http://bob:mypass@res.proxy.net:8080');
    assert.deepEqual(res, {
      protocol: 'http',
      host: 'res.proxy.net',
      port: 8080,
      username: 'bob',
      password: 'mypass'
    });
  });

  it('should parse openvpn:// and ovpn:// url with user/pass', () => {
    const res1 = parseProxyString('openvpn://vpn:vpn@219.100.37.13:443');
    assert.deepEqual(res1, {
      protocol: 'openvpn',
      host: '219.100.37.13',
      port: 443,
      username: 'vpn',
      password: 'vpn',
      proto: 'tcp',
    });

    const res2 = parseProxyString('ovpn://customuser:custompass@104.28.1.2:1194');
    assert.deepEqual(res2, {
      protocol: 'openvpn',
      host: '104.28.1.2',
      port: 1194,
      username: 'customuser',
      password: 'custompass',
      proto: 'tcp',
    });
  });

  it('should parse raw .ovpn configuration text and Base64 encoded ovpn', () => {
    const ovpnText = `
client
dev tun
proto tcp
remote 219.100.37.13 443
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
verb 2
<ca>
-----BEGIN CERTIFICATE-----
MIIB...
-----END CERTIFICATE-----
</ca>
    `;
    const res = parseProxyString(ovpnText);
    assert.ok(res);
    assert.equal(res.protocol, 'openvpn');
    assert.equal(res.host, '219.100.37.13');
    assert.equal(res.port, 443);
    assert.equal(res.username, 'vpn');
    assert.equal(res.hasCa, true);
    assert.ok(res.ca.includes('BEGIN CERTIFICATE'));

    // Base64
    const b64 = Buffer.from(ovpnText).toString('base64');
    const resB64 = parseProxyString(b64);
    assert.ok(resB64);
    assert.equal(resB64.protocol, 'openvpn');
    assert.equal(resB64.host, '219.100.37.13');
  });

  it('should parse host:port:user:pass format', () => {
    const res = parseProxyString('192.168.1.100:1080:testuser:testpass');
    assert.deepEqual(res, {
      protocol: 'socks5',
      host: '192.168.1.100',
      port: 1080,
      username: 'testuser',
      password: 'testpass'
    });
  });

  it('should parse user:pass@host:port format', () => {
    const res = parseProxyString('user1:pass1@1.2.3.4:9050');
    assert.deepEqual(res, {
      protocol: 'socks5',
      host: '1.2.3.4',
      port: 9050,
      username: 'user1',
      password: 'pass1'
    });
  });

  it('should return null for empty or invalid proxy', () => {
    assert.equal(parseProxyString(''), null);
    assert.equal(parseProxyString(null), null);
    assert.equal(parseProxyString(undefined), null);
    assert.equal(parseProxyString('not a valid proxy format!'), null);
  });
});



describe('VLESS Protocol Parser', () => {
  const testUUID = 'd342d11e-d424-4583-b36e-524ab1f0afa4';

  function createMockVlessHeader(uuidStr, targetType, targetAddr, targetPort, payloadStr = 'GET / HTTP/1.1\r\n') {
    // 16-byte UUID from string
    const hex = uuidStr.replace(/-/g, '');
    const uuidBytes = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      uuidBytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    }

    let addrBytes;
    let addrTypeByte;

    if (targetType === 'ipv4') {
      addrTypeByte = 0x01;
      addrBytes = new Uint8Array(targetAddr.split('.').map(Number));
    } else if (targetType === 'domain') {
      addrTypeByte = 0x02;
      const dBytes = new TextEncoder().encode(targetAddr);
      addrBytes = new Uint8Array(1 + dBytes.length);
      addrBytes[0] = dBytes.length;
      addrBytes.set(dBytes, 1);
    }

    const payloadBytes = new TextEncoder().encode(payloadStr);

    const buf = new Uint8Array(1 + 16 + 1 + 1 + 2 + 1 + addrBytes.length + payloadBytes.length);
    buf[0] = 0x00; // version
    buf.set(uuidBytes, 1);
    buf[17] = 0x00; // addon length = 0
    buf[18] = 0x01; // command = TCP (1)
    buf[19] = (targetPort >> 8) & 0xff;
    buf[20] = targetPort & 0xff;
    buf[21] = addrTypeByte;
    buf.set(addrBytes, 22);
    buf.set(payloadBytes, 22 + addrBytes.length);

    return buf;
  }

  it('should successfully parse a valid VLESS header with domain', () => {
    const packet = createMockVlessHeader(testUUID, 'domain', 'www.google.com', 443);
    const parsed = parseVlessHeader(packet, testUUID);

    assert.equal(parsed.success, true);
    assert.equal(parsed.version, 0);
    assert.equal(parsed.command, 1);
    assert.equal(parsed.port, 443);
    assert.equal(parsed.address, 'www.google.com');
    assert.equal(parsed.addressType, 2);
    assert.equal(new TextDecoder().decode(parsed.payload), 'GET / HTTP/1.1\r\n');
  });

  it('should successfully parse a valid VLESS header with IPv4', () => {
    const packet = createMockVlessHeader(testUUID, 'ipv4', '1.1.1.1', 80);
    const parsed = parseVlessHeader(packet, testUUID);

    assert.equal(parsed.success, true);
    assert.equal(parsed.command, 1);
    assert.equal(parsed.port, 80);
    assert.equal(parsed.address, '1.1.1.1');
    assert.equal(parsed.addressType, 1);
  });

  it('should reject when UUID does not match', () => {
    const packet = createMockVlessHeader('00000000-0000-0000-0000-000000000000', 'domain', 'example.com', 443);
    const parsed = parseVlessHeader(packet, testUUID);

    assert.equal(parsed.success, false);
    assert.match(parsed.error, /UUID mismatch/);
  });
});

describe('Node & Config Generators', () => {
  const config = {
    uuid: 'd342d11e-d424-4583-b36e-524ab1f0afa4',
    proxyPath: '/my-custom-ws',
    cleanIPs: '1.2.3.4\ncf.example.com',
    nodeName: 'TestNode',
    adminPassword: 'Password123'
  };
  const domain = 'my-worker.workers.dev';

  it('should generate valid VLESS URL with correct parameters', () => {
    const url = generateVlessUrl({
      uuid: config.uuid,
      host: domain,
      port: 443,
      workerDomain: domain,
      proxyPath: config.proxyPath,
      nodeName: 'TestNode'
    });

    assert.ok(url.startsWith(`vless://${config.uuid}@${domain}:443`));
    assert.ok(url.includes('path=%2Fmy-custom-ws'));
    assert.ok(url.includes('security=tls'));
    assert.ok(url.includes('type=ws'));
  });

  it('should parse sub.19910417.xyz response lines accurately', async () => {
    const { parseVlessSubResponse } = await import('../src/sub.js');
    const mockRawData = [
      'vless://d342d11e-d424-4583-b36e-524ab1f0afa4@103.135.249.52:443?encryption=none&security=tls&sni=example.com&fp=chrome&type=ws&host=example.com&path=%2F#HK%E8%87%AA%E7%94%A8',
      'vless://d342d11e-d424-4583-b36e-524ab1f0afa4@38.207.178.173:2087?encryption=none&security=tls&sni=example.com&fp=chrome&type=ws&host=example.com&path=%2F#HK%E8%87%AA%E7%94%A8',
      'vless://d342d11e-d424-4583-b36e-524ab1f0afa4@216.23.84.34:443?encryption=none&security=tls&sni=example.com&fp=chrome&type=ws&host=example.com&path=%2F#JP%E8%87%AA%E7%94%A8',
      'vless://d342d11e-d424-4583-b36e-524ab1f0afa4@example.com:443?encryption=none#Ignored',
      'vless://d342d11e-d424-4583-b36e-524ab1f0afa4@1.2.3.4:443?encryption=none#%E4%B8%8D%E5%86%8D%E6%94%AF%E6%8C%81%E6%97%A7%E7%89%88',
    ].join('\n');

    const nodes = parseVlessSubResponse(mockRawData, config, domain);
    assert.equal(nodes.length, 3);
    assert.equal(nodes[0].host, '103.135.249.52');
    assert.equal(nodes[0].port, 443);
    assert.ok(nodes[0].name.includes('HK自用-01'));
    assert.ok(nodes[0].url.includes('path=%2Fmy-custom-ws'));
    assert.ok(nodes[0].url.includes(`sni=${domain}`));

    assert.equal(nodes[1].host, '38.207.178.173');
    assert.equal(nodes[1].port, 2087);
    assert.equal(nodes[2].host, '216.23.84.34');
    assert.equal(nodes[2].port, 443);
  });

  it('should parse Base64 encoded sub.19910417.xyz response', async () => {
    const { parseVlessSubResponse } = await import('../src/sub.js');
    const rawLine = 'vless://d342d11e-d424-4583-b36e-524ab1f0afa4@104.16.1.1:443?encryption=none#US-Node';
    const b64Data = Buffer.from(rawLine).toString('base64');

    const nodes = parseVlessSubResponse(b64Data, config, domain);
    assert.equal(nodes.length, 1);
    assert.equal(nodes[0].host, '104.16.1.1');
    assert.ok(nodes[0].name.includes('US-Node-01'));
  });

  it('should generate all nodes including preferred IPs and fallback IPs', async () => {
    const nodes = await generateAllVlessNodes(config, domain);
    assert.ok(nodes.length >= 1);
    assert.equal(nodes[0].host, domain);
    assert.equal(nodes[0].category, 'direct');
  });

  it('should generate Sing-box outbound configuration JSON', () => {
    const singboxStr = generateSingboxConfig(config, domain);
    const singboxObj = JSON.parse(singboxStr);
    assert.equal(Array.isArray(singboxObj), true);
    assert.equal(singboxObj[0].type, 'vless');
    assert.equal(singboxObj[0].transport.path, '/my-custom-ws');
    assert.equal(singboxObj[0].tls.enabled, true);
    assert.equal(singboxObj[0].tls.server_name, domain);
  });

  it('should generate Sing-box full subscription profile with auto-selector-tcp and Base64 subscription', async () => {
    const { generateSingboxFullProfile, generateBase64Sub, buildUpstreamOutbound, injectSingboxChainProxy } = await import('../src/sub.js');
    
    // 1. Sing-box Full Profile (无上游代理)
    const sbFull = generateSingboxFullProfile(config, domain);
    const sbObj = JSON.parse(sbFull);
    assert.ok(sbObj.inbounds && sbObj.outbounds && sbObj.route);
    assert.equal(sbObj.outbounds[0].tag, '🚀 节点选择');
    assert.equal(sbObj.outbounds[1].tag, 'auto-selector-tcp');

    // 2. 带有 SOCKS5 住宅代理的链式代理配置生成
    const configWithSocks = {
      ...config,
      upstreamProxy: 'socks5://user:pass@1.2.3.4:1080'
    };
    const sbWithSocks = generateSingboxFullProfile(configWithSocks, domain);
    const sbSocksObj = JSON.parse(sbWithSocks);
    
    // 第 1 站：auto-selector-tcp (urltest)
    const urltestNode = sbSocksObj.outbounds.find(o => o.tag === 'auto-selector-tcp');
    assert.ok(urltestNode);
    assert.equal(urltestNode.type, 'urltest');
    
    // 最终出站：SOCKS5 节点，detour 设置为 auto-selector-tcp
    const socksNode = sbSocksObj.outbounds.find(o => o.tag === '🛡️ SOCKS5 住宅出口');
    assert.ok(socksNode);
    assert.equal(socksNode.type, 'socks');
    assert.equal(socksNode.server, '1.2.3.4');
    assert.equal(socksNode.server_port, 1080);
    assert.equal(socksNode.detour, 'auto-selector-tcp');

    // 主选择组默认指向 SOCKS5 住宅出口
    assert.equal(sbSocksObj.outbounds[0].default, '🛡️ SOCKS5 住宅出口');
    assert.equal(sbSocksObj.outbounds[0].outbounds[0], '🛡️ SOCKS5 住宅出口');

    // 3. 带有 HTTP 住宅代理的链式代理配置生成
    const configWithHttp = {
      ...config,
      upstreamProxy: 'http://user:pass@5.6.7.8:8080'
    };
    const sbWithHttp = generateSingboxFullProfile(configWithHttp, domain);
    const sbHttpObj = JSON.parse(sbWithHttp);
    const httpNode = sbHttpObj.outbounds.find(o => o.tag === '🛡️ HTTP 住宅出口');
    assert.ok(httpNode);
    assert.equal(httpNode.type, 'http');
    assert.equal(httpNode.server, '5.6.7.8');
    assert.equal(httpNode.server_port, 8080);
    assert.equal(httpNode.detour, 'auto-selector-tcp');
    assert.equal(sbHttpObj.outbounds[0].default, '🛡️ HTTP 住宅出口');

    // 4. 验证当 upstreamProxy 为 OpenVPN 时，生成的 Sing-box 配置不包含任何 OpenVPN 节点或 endpoint
    const configWithOvpn = {
      ...config,
      upstreamProxy: 'openvpn://vpn:vpn@219.100.37.13:443'
    };
    const sbWithOvpn = generateSingboxFullProfile(configWithOvpn, domain);
    const sbOvpnObj = JSON.parse(sbWithOvpn);
    
    // 验证 endpoints 为空或不存在，且没有 openvpn 出口
    assert.equal(sbOvpnObj.endpoints, undefined, 'Generated singbox config must NOT contain endpoints for openvpn');
    assert.equal(sbOvpnObj.outbounds.some(o => o.tag.includes('OpenVPN')), false, 'Must not contain OpenVPN outbound');
    assert.equal(sbOvpnObj.outbounds[0].default, 'auto-selector-tcp', 'Should default to auto-selector-tcp when no residential socks/http proxy is set');

    // 验证带 CA 证书的 OpenVPN 配置同样不会在 Sing-box 中生成 endpoint
    const configWithCaOvpn = {
      ...config,
      upstreamProxy: 'client\ndev tun\nproto tcp\nremote 219.100.37.13 443\n<ca>\n-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n</ca>'
    };
    const sbWithCaOvpn = JSON.parse(generateSingboxFullProfile(configWithCaOvpn, domain));
    assert.equal(sbWithCaOvpn.endpoints, undefined, 'Must NOT contain endpoints');

    // 验证 1.14.0 inbounds 无废弃 legacy 字段，且 route.rules 包含 sniff 规则
    assert.equal(sbOvpnObj.inbounds[0].sniff, undefined);
    assert.equal(sbOvpnObj.inbounds[0].domain_strategy, undefined);
    assert.ok(sbOvpnObj.route.rules.some(r => r.action === 'sniff'));

    // 验证 1.14.0 绝不包含已废弃被移除的 type: "dns" outbound
    assert.equal(sbOvpnObj.outbounds.some(o => o.type === 'dns'), false, 'Sing-box 1.14.0 must not contain dns outbound');
    assert.ok(sbOvpnObj.route.rules.some(r => r.action === 'hijack-dns'), 'Must use hijack-dns rule action');

    // 5. 链式代理注入函数 injectSingboxChainProxy (测试清洗旧版 subapi 响应中的 legacy 字段、dns outbound 以及 openvpn-client endpoints)
    const mockLegacySubapiResponse = JSON.stringify({
      inbounds: [
        { type: 'mixed', tag: 'mixed-in', sniff: true, domain_strategy: 'prefer_ipv4' }
      ],
      endpoints: [
        { type: 'openvpn-client', tag: 'legacy-ovpn', server: '1.2.3.4' }
      ],
      outbounds: [
        { type: 'selector', tag: 'PROXY', outbounds: ['⚡ 自动优选', 'DIRECT'], default: '⚡ 自动优选' },
        { type: 'urltest', tag: '⚡ 自动优选', outbounds: ['node1', 'node2'] },
        { type: 'vless', tag: 'node1' },
        { type: 'vless', tag: 'node2' },
        { type: 'dns', tag: 'dns-out' }
      ],
      route: {
        rules: [
          { protocol: 'dns', outbound: 'dns-out' }
        ],
        rule_set: [
          { type: 'remote', tag: 'geoip-cn', format: 'binary', url: 'https://example.com/geoip.db', download_detour: 'DIRECT' }
        ]
      }
    });
    const injected = injectSingboxChainProxy(mockLegacySubapiResponse, configWithSocks);
    const injectedObj = JSON.parse(injected);
    assert.equal(injectedObj.inbounds[0].sniff, undefined); // 旧字段已被清洗
    assert.equal(injectedObj.outbounds.some(o => o.type === 'dns'), false); // 旧 dns outbound 已被清洗
    assert.equal(injectedObj.endpoints, undefined, 'OpenVPN endpoint must be cleaned and deleted');
    assert.ok(injectedObj.route.rules.some(r => r.action === 'hijack-dns')); // 自动转换为 hijack-dns

    // 验证 rule_set 中的 download_detour 自动迁移为 http_clients
    assert.equal(injectedObj.route.rule_set[0].download_detour, undefined);
    assert.equal(injectedObj.route.rule_set[0].http_client, 'default-http');
    assert.ok(Array.isArray(injectedObj.http_clients));
    assert.equal(injectedObj.http_clients[0].tag, 'default-http');

    // 验证主选择组默认首选指向 SOCKS5 住宅出口以实现链式代理
    assert.equal(injectedObj.outbounds[0].default, '🛡️ SOCKS5 住宅出口');
    assert.equal(injectedObj.route.final, '🛡️ SOCKS5 住宅出口');

    // 验证直连 DNS 绝不包含 direct detour (避免 'detour to an empty direct outbound makes no sense')
    if (sbOvpnObj.dns && sbOvpnObj.dns.servers) {
      const localDns = sbOvpnObj.dns.servers.find(s => s.tag === 'dns-local');
      if (localDns) assert.equal(localDns.detour, undefined);
    }

    // 6. Base64 Sub
    const b64 = generateBase64Sub(config, domain);
    assert.equal(typeof b64, 'string');
    assert.ok(b64.length > 20);
  });

  it('should properly hash passwords and normalize paths', async () => {
    const hash1 = await hashPassword('secret');
    const hash2 = await hashPassword('secret');
    assert.equal(hash1, hash2);
    assert.equal(typeof hash1, 'string');
    assert.equal(hash1.length, 64);

    assert.equal(normalizePath('foo'), '/foo');
    assert.equal(normalizePath('/foo/'), '/foo');
    assert.equal(normalizePath(''), '/');
  });
});

describe('Worker Request Routing & API Endpoints', () => {
  const env = {
    DEFAULT_UUID: 'd342d11e-d424-4583-b36e-524ab1f0afa4',
    DEFAULT_DATA_PATH: '/test-ws',
    ADMIN_PASSWORD: 'Password123!',
  };

  it('should respond to /v2ray with Base64 content when authorized', async () => {
    const worker = (await import('../src/index.js')).default;
    const token = await hashPassword('Password123!');
    const req = new Request(`https://my-worker.workers.dev/v2ray?token=${token}`);
    const res = await worker.fetch(req, env, {});

    assert.equal(res.status, 200);
    assert.equal(res.headers.get('Content-Type'), 'text/plain; charset=utf-8');
    const body = await res.text();
    assert.ok(body.length > 10);
    const decoded = atob(body);
    assert.ok(decoded.includes('vless://'));
  });

  it('should reject unauthorized /v2ray and return landing page', async () => {
    const worker = (await import('../src/index.js')).default;
    const req = new Request('https://my-worker.workers.dev/v2ray?token=invalid_token');
    const res = await worker.fetch(req, env, {});

    assert.equal(res.status, 200);
    assert.equal(res.headers.get('Content-Type'), 'text/html; charset=utf-8');
    const body = await res.text();
    assert.ok(body.includes('汉武大帝'));
  });

  it('should handle /admin/api/login and /admin/api/subconfigs', async () => {
    const worker = (await import('../src/index.js')).default;
    
    // Login
    const loginReq = new Request('https://my-worker.workers.dev/admin/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: 'Password123!' })
    });
    const loginRes = await worker.fetch(loginReq, env, {});
    assert.equal(loginRes.status, 200);
    const loginData = await loginRes.json();
    assert.equal(loginData.success, true);
    assert.ok(loginData.token);

    // Subconfigs
    const subcfgReq = new Request('https://my-worker.workers.dev/admin/api/subconfigs');
    const subcfgRes = await worker.fetch(subcfgReq, env, {});
    assert.equal(subcfgRes.status, 200);
  });
});

describe('REST API Proxy Management & Dedicated Token Auth', () => {
  const customApiToken = 'my-custom-push-token-123456';
  
  // 创建一个模拟的 KV Storage 内存对象
  function createMockKV() {
    const store = new Map();
    return {
      async get(key, opts) {
        const val = store.get(key);
        if (!val) return null;
        if (opts && opts.type === 'json') {
          return JSON.parse(val);
        }
        return val;
      },
      async put(key, value) {
        store.set(key, typeof value === 'string' ? value : JSON.stringify(value));
      }
    };
  }

  const mockKV = createMockKV();
  const env = {
    DEFAULT_UUID: 'd342d11e-d424-4583-b36e-524ab1f0afa4',
    DEFAULT_DATA_PATH: '/test-ws',
    ADMIN_PASSWORD: 'AdminPassword123!',
    API_TOKEN: customApiToken,
    CONFIG_KV: mockKV,
  };

  it('should verify dedicated API Token correctly via Header and Query Param', async () => {
    const { verifyApiToken } = await import('../src/config.js');
    const config = { apiToken: customApiToken, adminPassword: 'AdminPassword123!' };

    // 1. Bearer Token
    const reqBearer = new Request('https://domain/api/upstream', {
      headers: { 'Authorization': `Bearer ${customApiToken}` }
    });
    assert.equal(await verifyApiToken(reqBearer, config), true);

    // 2. X-API-Token
    const reqXApi = new Request('https://domain/api/upstream', {
      headers: { 'X-API-Token': customApiToken }
    });
    assert.equal(await verifyApiToken(reqXApi, config), true);

    // 3. Query Param ?token=
    const reqQuery = new Request(`https://domain/api/upstream?token=${customApiToken}`);
    assert.equal(await verifyApiToken(reqQuery, config), true);

    // 4. Query Param ?api_token=
    const reqQuery2 = new Request(`https://domain/api/upstream?api_token=${customApiToken}`);
    assert.equal(await verifyApiToken(reqQuery2, config), true);

    // 5. Invalid Token
    const reqInvalid = new Request('https://domain/api/upstream', {
      headers: { 'Authorization': 'Bearer wrong-token' }
    });
    assert.equal(await verifyApiToken(reqInvalid, config), false);

    // 6. Missing Token
    const reqMissing = new Request('https://domain/api/upstream');
    assert.equal(await verifyApiToken(reqMissing, config), false);
  });

  it('should reject unauthenticated request with 401 Unauthorized', async () => {
    const worker = (await import('../src/index.js')).default;
    const req = new Request('https://my-worker.workers.dev/api/upstream', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ upstreamProxy: 'socks5://user:pass@1.2.3.4:1080' })
    });
    const res = await worker.fetch(req, env, {});
    assert.equal(res.status, 401);
    const data = await res.json();
    assert.equal(data.success, false);
    assert.ok(data.error.includes('Unauthorized'));
  });

  it('should query upstream proxy info via GET /api/upstream with token', async () => {
    const worker = (await import('../src/index.js')).default;
    const req = new Request('https://my-worker.workers.dev/api/upstream', {
      method: 'GET',
      headers: { 'Authorization': `Bearer ${customApiToken}` }
    });
    const res = await worker.fetch(req, env, {});
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.success, true);
    assert.equal(typeof data.upstreamProxy, 'string');
  });

  it('should update upstream proxy with SOCKS5 URL format via POST /api/upstream', async () => {
    const worker = (await import('../src/index.js')).default;
    const socks5Url = 'socks5://user:pass@1.2.3.4:1080';

    const req = new Request('https://my-worker.workers.dev/api/upstream', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${customApiToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        upstreamProxy: socks5Url,
        enableDirectFallback: true
      })
    });
    const res = await worker.fetch(req, env, {});
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.success, true);
    assert.equal(data.upstreamProxy, socks5Url);
    assert.equal(data.parsed.protocol, 'socks5');
    assert.equal(data.parsed.host, '1.2.3.4');
    assert.equal(data.parsed.port, 1080);
    assert.equal(data.parsed.username, 'user');
    assert.equal(data.parsed.password, 'pass');

    // 验证 GET /api/upstream 读取到更新后的 SOCKS5 配置
    const checkReq = new Request('https://my-worker.workers.dev/api/upstream', {
      headers: { 'X-API-Token': customApiToken }
    });
    const checkRes = await worker.fetch(checkReq, env, {});
    const checkData = await checkRes.json();
    assert.equal(checkData.upstreamProxy, socks5Url);
    assert.equal(checkData.parsed.protocol, 'socks5');
  });

  it('should update upstream proxy with raw .ovpn configuration text via POST /api/upstream', async () => {
    const worker = (await import('../src/index.js')).default;
    const ovpnConfig = 'client\ndev tun\nproto tcp\nremote 133.242.18.25 995\nauth-user-pass\n<ca>\nMIIB...\n</ca>';

    const req = new Request('https://my-worker.workers.dev/api/upstream', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${customApiToken}`,
        'Content-Type': 'text/plain',
      },
      body: ovpnConfig
    });
    const res = await worker.fetch(req, env, {});
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.success, true);
    assert.equal(data.parsed.protocol, 'openvpn');
    assert.equal(data.parsed.host, '133.242.18.25');
    assert.equal(data.parsed.port, 995);
    assert.equal(data.parsed.username, 'vpn');
  });

  it('should respond to /singbox and /sub with valid Sing-box JSON profile', async () => {
    const worker = (await import('../src/index.js')).default;
    const token = await hashPassword('AdminPassword123!');
    const req = new Request(`https://my-worker.workers.dev/singbox?token=${token}`);
    const res = await worker.fetch(req, env, {});

    assert.equal(res.status, 200);
    assert.equal(res.headers.get('Content-Type'), 'application/json; charset=utf-8');
    const body = await res.json();
    assert.ok(body.outbounds && body.inbounds);
    assert.equal(body.outbounds[0].tag, '🚀 节点选择');
  });

  it('should reject invalid proxy format with 400 Bad Request', async () => {
    const worker = (await import('../src/index.js')).default;
    const req = new Request('https://my-worker.workers.dev/api/upstream', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${customApiToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        upstreamProxy: 'invalid-nonexistent-protocol-xyz'
      })
    });
    const res = await worker.fetch(req, env, {});
    assert.equal(res.status, 400);
    const data = await res.json();
    assert.equal(data.success, false);
    assert.ok(data.error.includes('无法解析'));
  });

  it('should auto-generate API_TOKEN and persist to KV when not present', async () => {
    const { getConfig } = await import('../src/config.js');
    const freshKV = createMockKV();
    const freshEnv = {
      CONFIG_KV: freshKV,
      ADMIN_PASSWORD: 'Password123!',
    };

    // 首次获取配置，未提供 API_TOKEN
    const cfg1 = await getConfig(freshEnv);
    assert.ok(cfg1.apiToken);
    assert.ok(cfg1.apiToken.startsWith('cf-push-'));

    // 验证 KV 中已被持久化存储
    const storedInKV = await freshKV.get('app_config', { type: 'json' });
    assert.ok(storedInKV);
    assert.equal(storedInKV.apiToken, cfg1.apiToken);

    // 再次调用 getConfig，获取到的是同一个持久化的 API_TOKEN
    const cfg2 = await getConfig(freshEnv);
    assert.equal(cfg2.apiToken, cfg1.apiToken);
  });

  it('should generate random API tokens with proper format', async () => {
    const { generateRandomApiToken } = await import('../src/config.js');
    const t1 = generateRandomApiToken();
    const t2 = generateRandomApiToken();
    assert.notEqual(t1, t2);
    assert.ok(t1.startsWith('cf-push-'));
    assert.ok(t1.length >= 20);
  });
});

describe('Static Landing Page & Admin HTML Integrity', () => {
  it('should render Han Wudi biography landing page with proper DOM structure', async () => {
    const { renderLandingPage } = await import('../src/landing.js');
    const html = renderLandingPage();
    assert.ok(html.includes('汉武大帝'));
    assert.ok(html.includes('刘彻'));
    assert.ok(html.includes('推恩令'));
    assert.ok(html.includes('封狼居胥'));
    assert.ok(html.includes('丝绸之路'));
    assert.ok(html.includes('<!DOCTYPE html>'));
  });

  it('should render valid Admin SPA HTML with 100% syntactically compilable client JavaScript', async () => {
    const { handleAdmin } = await import('../src/admin.js');
    const res = await handleAdmin(new Request('https://domain/admin'), {}, new URL('https://domain/admin'), { adminPath: '/admin' });
    const html = await res.text();
    assert.equal(res.status, 200);
    assert.ok(html.includes('id="login-overlay"'));
    assert.ok(html.includes('id="login-pass"'));
    assert.ok(html.includes('doLogin()'));

    // Extract script tag and verify with node:vm Script
    const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
    assert.ok(scriptMatch, 'script tag must exist in admin HTML');
    const scriptCode = scriptMatch[1];
    
    const vm = await import('node:vm');
    assert.doesNotThrow(() => {
      new vm.Script(scriptCode);
    }, 'Client-side script in admin HTML must compile without any SyntaxError');
  });

  it('should record, query and clear system logs in logger module and admin API', async () => {
    const { logSystem, getSystemLogs, clearSystemLogs } = await import('../src/logger.js');
    const mockStore = new Map();
    const mockKV = {
      async get(key) { return mockStore.get(key) || null; },
      async put(key, val) { mockStore.set(key, val); },
      async delete(key) { mockStore.delete(key); },
    };
    const env = { CONFIG_KV: mockKV };

    // 1. 记录日志
    await logSystem(env, { level: 'ERROR', module: 'TestModule', message: '测试错误信息', details: { code: 500 }, ip: '1.2.3.4' });
    await logSystem(env, { level: 'INFO', module: 'TestModule', message: '测试普通信息' });

    // 2. 查询日志
    const logs = await getSystemLogs(env);
    assert.ok(Array.isArray(logs));
    assert.equal(logs.length, 2);
    assert.equal(logs[0].level, 'INFO');
    assert.equal(logs[1].level, 'ERROR');
    assert.equal(logs[1].module, 'TestModule');
    assert.equal(logs[1].ip, '1.2.3.4');

    // 3. 清空日志
    const clearRes = await clearSystemLogs(env);
    assert.equal(clearRes, true);
    const emptyLogs = await getSystemLogs(env);
    assert.equal(emptyLogs.length, 0);
  });
});



