import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseProxyString } from '../src/upstream.js';
import { parseVlessHeader, bytesToUUID } from '../src/vless.js';
import { generateVlessUrl, generateAllVlessNodes, generateSingboxConfig, generateClashMetaConfig } from '../src/sub.js';
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

  it('should generate Sing-box and Clash Meta outbound configurations', () => {
    const singboxStr = generateSingboxConfig(config, domain);
    const singboxObj = JSON.parse(singboxStr);
    assert.equal(Array.isArray(singboxObj), true);
    assert.equal(singboxObj[0].type, 'vless');
    assert.equal(singboxObj[0].transport.path, '/my-custom-ws');

    const clashYaml = generateClashMetaConfig(config, domain);
    assert.ok(clashYaml.includes('type: vless'));
    assert.ok(clashYaml.includes('network: ws'));
    assert.ok(clashYaml.includes('path: "/my-custom-ws"'));
  });

  it('should generate Sing-box and Clash Meta full subscription profiles', async () => {
    const { generateSingboxFullProfile, generateClashFullProfile, generateBase64Sub } = await import('../src/sub.js');
    
    // 1. Sing-box Full Profile
    const sbFull = generateSingboxFullProfile(config, domain);
    const sbObj = JSON.parse(sbFull);
    assert.ok(sbObj.inbounds && sbObj.outbounds && sbObj.route);
    assert.equal(sbObj.outbounds[0].tag, '🚀 节点选择');

    // 2. Clash Full Profile
    const clashFull = generateClashFullProfile(config, domain);
    assert.ok(clashFull.includes('proxy-groups:'));
    assert.ok(clashFull.includes('🚀 节点选择'));
    assert.ok(clashFull.includes('⚡ 自动优选'));

    // 3. Base64 Sub
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

describe('Static Landing Page', () => {
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
});


