/**
 * Upstream Connection Handler
 * Supports Direct TCP connections, SOCKS5 Residential Proxies (with/without Auth),
 * and HTTP CONNECT Proxies (with/without Auth).
 */

async function getConnectFn() {
  try {
    const { connect } = await import('cloudflare:sockets');
    return connect;
  } catch (e) {
    throw new Error('cloudflare:sockets is only available in Cloudflare Workers runtime.');
  }
}


/**
 * 解析 OpenVPN 配置文件文本或 Base64 编码字符串
 * 提取 remote 主机、端口、协议、认证信息以及内置 CA 根证书 / 客户端证书
 * @param {string} content 
 * @returns {object|null}
 */
export function parseOpenVpnConfig(content) {
  if (!content || typeof content !== 'string') return null;
  let text = content.trim();

  // 如果字符串为 Base64 编码的 ovpn，尝试解码
  if (!text.includes('\n') && text.length > 20) {
    try {
      let decoded = '';
      if (typeof atob === 'function') {
        decoded = atob(text.replace(/\s/g, ''));
      } else if (typeof Buffer !== 'undefined') {
        decoded = Buffer.from(text.replace(/\s/g, ''), 'base64').toString('utf-8');
      }
      if (decoded && (decoded.includes('remote ') || decoded.includes('client') || decoded.includes('dev tun') || decoded.includes('<ca>'))) {
        text = decoded;
      }
    } catch (_) {}
  }

  // 必须包含 remote 指令、client 特征或 <ca> 块
  if (!text.includes('remote ') && !text.includes('client') && !text.includes('dev tun') && !text.includes('<ca>')) {
    return null;
  }

  let host = '';
  let port = 443;
  let username = 'vpn';
  let password = 'vpn';
  let proto = 'tcp';
  let cipher = '';
  let auth = '';

  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('#') || trimmed.startsWith(';')) continue;

    if (trimmed.startsWith('proto ')) {
      const parts = trimmed.split(/\s+/);
      if (parts.length >= 2) {
        proto = parts[1].toLowerCase();
      }
    } else if (trimmed.startsWith('remote ')) {
      const parts = trimmed.split(/\s+/);
      if (parts.length >= 2 && !host) {
        host = parts[1].trim();
        if (parts.length >= 3) {
          const parsedPort = parseInt(parts[2].trim(), 10);
          if (!isNaN(parsedPort) && parsedPort > 0) {
            port = parsedPort;
          }
        }
      }
    } else if (trimmed.startsWith('cipher ')) {
      cipher = trimmed.slice(7).trim();
    } else if (trimmed.startsWith('auth ')) {
      auth = trimmed.slice(5).trim();
    }
  }

  // 正则回退提取（防止换行符丢失或单行被压缩的情况）
  if (!host) {
    const remoteMatch = text.match(/(?:^|\s)remote\s+([a-zA-Z0-9\.\-\_]+)(?:\s+(\d+))?/i);
    if (remoteMatch) {
      host = remoteMatch[1].trim();
      if (remoteMatch[2]) {
        const parsedPort = parseInt(remoteMatch[2].trim(), 10);
        if (!isNaN(parsedPort) && parsedPort > 0) {
          port = parsedPort;
        }
      }
    }
  }

  if (!cipher) {
    const cipherMatch = text.match(/(?:^|\s)cipher\s+([a-zA-Z0-9\-\_]+)/i);
    if (cipherMatch) cipher = cipherMatch[1].trim();
  }

  if (!auth) {
    const authMatch = text.match(/(?:^|\s)auth\s+([a-zA-Z0-9\-\_]+)/i);
    if (authMatch) auth = authMatch[1].trim();
  }

  const protoMatch = text.match(/(?:^|\s)proto\s+(tcp|udp)/i);
  if (protoMatch) {
    proto = protoMatch[1].toLowerCase();
  }

  // 提取 <ca> 根证书
  let ca = null;
  const caMatch = text.match(/<ca>([\s\S]*?)<\/ca>/i);
  if (caMatch) {
    ca = caMatch[1].trim();
  }

  // 提取 <cert> 客户端证书
  let cert = null;
  const certMatch = text.match(/<cert>([\s\S]*?)<\/cert>/i);
  if (certMatch) {
    cert = certMatch[1].trim();
  }

  // 提取 <key> 客户端私钥
  let key = null;
  const keyMatch = text.match(/<key>([\s\S]*?)<\/key>/i);
  if (keyMatch) {
    key = keyMatch[1].trim();
  }

  // 提取 <tls-auth>
  let tlsAuth = null;
  const tlsAuthMatch = text.match(/<tls-auth>([\s\S]*?)<\/tls-auth>/i);
  if (tlsAuthMatch) {
    tlsAuth = tlsAuthMatch[1].trim();
  }

  if (!host) return null;

  return {
    protocol: 'openvpn',
    host,
    port,
    username,
    password,
    proto,
    cipher: cipher || undefined,
    auth: auth || undefined,
    hasCa: Boolean(ca),
    ca: ca || undefined,
    cert: cert || undefined,
    key: key || undefined,
    tlsAuth: tlsAuth || undefined,
  };
}

/**
 * 解析各种格式的代理字符串
 * 支持格式：
 * 1. socks5://user:pass@host:port 或 socks5://host:port
 * 2. http://user:pass@host:port 或 http://host:port
 * 3. openvpn://user:pass@host:port 或 openvpn://host:port (默认凭据 vpn:vpn)
 * 4. ovpn://user:pass@host:port 或 ovpn://host:port (默认凭据 vpn:vpn)
 * 5. OpenVPN .ovpn 原始配置文件文本 (包含 remote host port)
 * 6. Base64 编码的 .ovpn 配置文件内容
 * 7. user:pass@host:port (默认为 socks5)
 * 8. host:port:user:pass (默认为 socks5)
 * 9. host:port (默认为 socks5)
 * @param {string} rawProxy
 * @returns {object|null}
 */
export function parseProxyString(rawProxy) {
  if (!rawProxy || typeof rawProxy !== 'string') return null;
  const str = rawProxy.trim();
  if (!str) return null;

  try {
    // 1. OpenVPN / OVPN 协议头
    if (str.startsWith('openvpn://') || str.startsWith('ovpn://')) {
      const cleanStr = str.replace(/^ovpn:\/\//i, 'openvpn://');
      const url = new URL(cleanStr);
      return {
        protocol: 'openvpn',
        host: url.hostname,
        port: parseInt(url.port, 10) || 443,
        username: decodeURIComponent(url.username || '') || 'vpn',
        password: decodeURIComponent(url.password || '') || 'vpn',
      };
    }

    // 2. OpenVPN .ovpn 文本或 Base64 字符串
    const ovpnParsed = parseOpenVpnConfig(str);
    if (ovpnParsed) {
      return ovpnParsed;
    }

    // 3. SOCKS5 / HTTP 协议头
    if (str.startsWith('socks5://') || str.startsWith('http://') || str.startsWith('https://')) {
      const url = new URL(str);
      const protocol = url.protocol.replace(':', '').toLowerCase();
      return {
        protocol: protocol === 'https' ? 'http' : protocol,
        host: url.hostname,
        port: parseInt(url.port, 10) || (protocol === 'http' ? 80 : 1080),
        username: decodeURIComponent(url.username || ''),
        password: decodeURIComponent(url.password || ''),
      };
    }

    // 4. host:port:user:pass 格式
    const parts = str.split(':');
    if (parts.length === 4 && !str.includes('@')) {
      return {
        protocol: 'socks5',
        host: parts[0].trim(),
        port: parseInt(parts[1].trim(), 10),
        username: parts[2].trim(),
        password: parts[3].trim(),
      };
    }

    // 5. user:pass@host:port 格式
    if (str.includes('@')) {
      const atSplit = str.split('@');
      const authParts = atSplit[0].split(':');
      const hostParts = atSplit[1].split(':');
      return {
        protocol: 'socks5',
        host: hostParts[0].trim(),
        port: parseInt(hostParts[1].trim(), 10) || 1080,
        username: authParts[0] ? authParts[0].trim() : '',
        password: authParts[1] ? authParts[1].trim() : '',
      };
    }

    // 6. host:port 格式
    if (parts.length === 2) {
      const parsedPort = parseInt(parts[1].trim(), 10);
      if (!isNaN(parsedPort) && parsedPort > 0) {
        return {
          protocol: 'socks5',
          host: parts[0].trim(),
          port: parsedPort,
          username: '',
          password: '',
        };
      }
    }
  } catch (err) {
    console.error('Error parsing proxy string:', rawProxy, err);
  }

  return null;
}

/**
 * 建立上游目标连接（支持直连或通过住宅代理 SOCKS5 / HTTP）
 * @param {string} targetHost 目标主机名或 IP
 * @param {number} targetPort 目标端口
 * @param {string} upstreamProxyConfig 上游住宅代理配置字符串
 * @param {boolean} enableFallback 代理失败时是否回退直连
 * @returns {Promise<{ socket: any, initialBuffer?: Uint8Array }>}
 */
export async function createUpstreamConnection(targetHost, targetPort, upstreamProxyConfig = '', enableFallback = true) {
  const proxy = parseProxyString(upstreamProxyConfig);

  // 未配置代理，直接直连
  if (!proxy) {
    console.log(`[Upstream:Direct] 正在建立直连 -> ${targetHost}:${targetPort}`);
    try {
      const connect = await getConnectFn();
      const socket = connect({
        hostname: targetHost,
        port: targetPort,
      });
      return { socket };
    } catch (directErr) {
      console.error(`[Upstream:Direct:Error] 直连失败 -> ${targetHost}:${targetPort}:`, directErr.message || directErr);
      throw directErr;
    }
  }

  // 通过住宅代理转发
  console.log(`[Upstream:Proxy] 正在通过住宅代理转发 -> 目标: ${targetHost}:${targetPort} | 代理服务器: ${proxy.protocol.toUpperCase()}://${proxy.host}:${proxy.port}`);
  try {
    if (proxy.protocol === 'socks5' || proxy.protocol === 'openvpn' || proxy.protocol === 'ovpn') {
      return await connectViaSocks5(proxy, targetHost, targetPort);
    } else if (proxy.protocol === 'http') {
      return await connectViaHttpConnect(proxy, targetHost, targetPort);
    } else {
      throw new Error(`Unsupported proxy protocol: ${proxy.protocol}`);
    }
  } catch (proxyErr) {
    console.error(`[Upstream:Proxy:Error] 住宅代理连接失败 [${proxy.protocol}://${proxy.host}:${proxy.port}] 目标: ${targetHost}:${targetPort} -> ${proxyErr.message}`);
    if (enableFallback) {
      console.warn(`[Upstream:Fallback] 住宅代理异常，正在回退至边缘直连模式 -> ${targetHost}:${targetPort}`);
      try {
        const connect = await getConnectFn();
        const socket = connect({
          hostname: targetHost,
          port: targetPort,
        });
        return { socket };
      } catch (fbErr) {
        console.error(`[Upstream:Fallback:Error] 代理故障回退直连亦失败 -> ${targetHost}:${targetPort}:`, fbErr.message || fbErr);
        throw fbErr;
      }
    }
    throw proxyErr;
  }
}

/**
 * 通过 SOCKS5 代理连接目标主机
 */
async function connectViaSocks5(proxy, targetHost, targetPort) {
  const connect = await getConnectFn();
  let socket;
  try {
    socket = connect({
      hostname: proxy.host,
      port: proxy.port,
    });
  } catch (sockErr) {
    console.error(`[SOCKS5:Socket:Error] 连接 SOCKS5 代理服务器 ${proxy.host}:${proxy.port} 失败:`, sockErr.message || sockErr);
    throw sockErr;
  }

  const reader = socket.readable.getReader();
  const writer = socket.writable.getWriter();

  try {
    // 1. 协商认证方法
    const hasAuth = !!(proxy.username || proxy.password);
    const greeting = hasAuth
      ? new Uint8Array([0x05, 0x02, 0x00, 0x02]) // 支持无认证与用户名密码认证
      : new Uint8Array([0x05, 0x01, 0x00]);       // 仅无认证

    await writer.write(greeting);

    const greetingRes = await readExactBytes(reader, 2);
    if (greetingRes[0] !== 0x05) {
      throw new Error(`SOCKS5 握手版本错误 (期望 0x05, 收到 0x${greetingRes[0].toString(16)})`);
    }

    const selectedMethod = greetingRes[1];

    // 2. 执行用户名/密码认证
    if (selectedMethod === 0x02) {
      const uBytes = new TextEncoder().encode(proxy.username);
      const pBytes = new TextEncoder().encode(proxy.password);
      const authPacket = new Uint8Array(3 + uBytes.length + pBytes.length);
      authPacket[0] = 0x01; // subnegotiation version
      authPacket[1] = uBytes.length;
      authPacket.set(uBytes, 2);
      authPacket[2 + uBytes.length] = pBytes.length;
      authPacket.set(pBytes, 3 + uBytes.length);

      await writer.write(authPacket);

      const authRes = await readExactBytes(reader, 2);
      if (authRes[1] !== 0x00) {
        throw new Error(`SOCKS5 authentication failed with status: ${authRes[1]}`);
      }
    } else if (selectedMethod === 0xFF) {
      throw new Error('SOCKS5 proxy rejected authentication methods');
    }

    // 3. 发送 SOCKS5 CONNECT 请求
    const isIPv4 = /^(\d{1,3}\.){3}\d{1,3}$/.test(targetHost);
    const isIPv6 = targetHost.includes(':');

    let destBytes;
    let atyp;

    if (isIPv4) {
      atyp = 0x01;
      destBytes = new Uint8Array(targetHost.split('.').map(Number));
    } else if (isIPv6) {
      atyp = 0x04;
      destBytes = parseIPv6(targetHost);
    } else {
      atyp = 0x03;
      const domainBytes = new TextEncoder().encode(targetHost);
      destBytes = new Uint8Array(1 + domainBytes.length);
      destBytes[0] = domainBytes.length;
      destBytes.set(domainBytes, 1);
    }

    const reqPacket = new Uint8Array(4 + destBytes.length + 2);
    reqPacket[0] = 0x05; // SOCKS version
    reqPacket[1] = 0x01; // CONNECT
    reqPacket[2] = 0x00; // RSV
    reqPacket[3] = atyp; // Address Type
    reqPacket.set(destBytes, 4);
    reqPacket[4 + destBytes.length] = (targetPort >> 8) & 0xff;
    reqPacket[5 + destBytes.length] = targetPort & 0xff;

    await writer.write(reqPacket);

    // 4. 读取 SOCKS5 响应头部 (4 字节: 0x05, rep, 0x00, atyp)
    const replyHeader = await readExactBytes(reader, 4);
    if (replyHeader[1] !== 0x00) {
      const errMsg = getSocks5ErrorMessage(replyHeader[1]);
      throw new Error(`SOCKS5 CONNECT failed: ${errMsg} (code: ${replyHeader[1]})`);
    }

    const replyAtyp = replyHeader[3];
    let remainingBytesCount = 0;
    if (replyAtyp === 0x01) {
      remainingBytesCount = 4 + 2; // IPv4 + Port
    } else if (replyAtyp === 0x03) {
      const lenBuf = await readExactBytes(reader, 1);
      remainingBytesCount = lenBuf[0] + 2; // Domain + Port
    } else if (replyAtyp === 0x04) {
      remainingBytesCount = 16 + 2; // IPv6 + Port
    }

    if (remainingBytesCount > 0) {
      await readExactBytes(reader, remainingBytesCount);
    }

    // 握手完成，释放 reader & writer 以便后续流式管道接管
    reader.releaseLock();
    writer.releaseLock();

    return { socket };
  } catch (err) {
    try { reader.releaseLock(); } catch (_) {}
    try { writer.releaseLock(); } catch (_) {}
    try { socket.close(); } catch (_) {}
    throw err;
  }
}

/**
 * 通过 HTTP CONNECT 隧道连接目标主机
 */
async function connectViaHttpConnect(proxy, targetHost, targetPort) {
  const connect = await getConnectFn();
  const socketOpts = {
    hostname: proxy.host,
    port: proxy.port,
  };
  if (proxy.protocol === 'https' || proxy.secureTransport === 'on') {
    socketOpts.secureTransport = 'on';
  }
  const socket = connect(socketOpts);

  const reader = socket.readable.getReader();
  const writer = socket.writable.getWriter();

  try {
    let connectReq = `CONNECT ${targetHost}:${targetPort} HTTP/1.1\r\n` +
      `Host: ${targetHost}:${targetPort}\r\n` +
      `Proxy-Connection: Keep-Alive\r\n` +
      `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\n`;

    if (proxy.username || proxy.password) {
      const creds = `${proxy.username}:${proxy.password}`;
      const authBase64 = btoa(creds);
      connectReq += `Proxy-Authorization: Basic ${authBase64}\r\n`;
    }
    connectReq += `\r\n`;

    await writer.write(new TextEncoder().encode(connectReq));

    // 读取 HTTP 响应头直到 \r\n\r\n
    let responseBuffer = new Uint8Array(0);
    let headerEndIndex = -1;

    // 异步安全读取
    while (headerEndIndex === -1) {
      const readPromise = reader.read();
      const timeoutPromise = new Promise((_, reject) =>
        setTimeout(() => reject(new Error('HTTP 代理握手读取超时 (60s)')), 60000)
      );

      const { value, done } = await Promise.race([readPromise, timeoutPromise]);
      if (done || !value) {
        throw new Error('HTTP proxy closed connection during CONNECT handshake');
      }

      const merged = new Uint8Array(responseBuffer.length + value.length);
      merged.set(responseBuffer);
      merged.set(value, responseBuffer.length);
      responseBuffer = merged;

      // 寻找 \r\n\r\n (0x0d 0x0a 0x0d 0x0a)
      for (let i = 0; i <= responseBuffer.length - 4; i++) {
        if (
          responseBuffer[i] === 0x0d &&
          responseBuffer[i + 1] === 0x0a &&
          responseBuffer[i + 2] === 0x0d &&
          responseBuffer[i + 3] === 0x0a
        ) {
          headerEndIndex = i + 4;
          break;
        }
      }
    }

    const headerText = new TextDecoder().decode(responseBuffer.slice(0, headerEndIndex));
    const statusLine = headerText.split('\r\n')[0];

    if (!statusLine.includes('200')) {
      throw new Error(`HTTP CONNECT failed: ${statusLine}`);
    }

    // 检查是否有握手后多余的数据
    let initialBuffer = null;
    if (responseBuffer.length > headerEndIndex) {
      initialBuffer = responseBuffer.slice(headerEndIndex);
    }

    reader.releaseLock();
    writer.releaseLock();

    return { socket, initialBuffer };
  } catch (err) {
    try { reader.releaseLock(); } catch (_) {}
    try { writer.releaseLock(); } catch (_) {}
    try { socket.close(); } catch (_) {}
    throw err;
  }
}

/**
 * 精确从 Reader 中读取指定长度的字节 (支持 60 秒超时保护)
 */
async function readExactBytes(reader, length, timeoutMs = 60000) {
  const result = new Uint8Array(length);
  let offset = 0;

  while (offset < length) {
    const readPromise = reader.read();
    const timeoutPromise = new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`读取响应超时 (${timeoutMs / 1000}s)`)), timeoutMs)
    );

    const { value, done } = await Promise.race([readPromise, timeoutPromise]);
    if (done || !value) {
      throw new Error(`Stream closed unexpectedly while reading ${length} bytes (got ${offset} bytes)`);
    }

    const needed = length - offset;
    if (value.length <= needed) {
      result.set(value, offset);
      offset += value.length;
    } else {
      result.set(value.subarray(0, needed), offset);
      offset += needed;
    }
  }

  return result;
}

/**
 * 解析 IPv6 字符串为 16 字节 Uint8Array
 */
function parseIPv6(ip) {
  const bytes = new Uint8Array(16);
  const parts = ip.split(':');
  let doubleColonIndex = parts.indexOf('');

  if (doubleColonIndex !== -1) {
    const head = parts.slice(0, doubleColonIndex).filter(Boolean);
    const tail = parts.slice(doubleColonIndex + 1).filter(Boolean);
    const missing = 8 - (head.length + tail.length);
    const fullParts = [...head, ...Array(missing).fill('0'), ...tail];
    for (let i = 0; i < 8; i++) {
      const val = parseInt(fullParts[i] || '0', 16);
      bytes[i * 2] = (val >> 8) & 0xff;
      bytes[i * 2 + 1] = val & 0xff;
    }
  } else {
    for (let i = 0; i < 8; i++) {
      const val = parseInt(parts[i] || '0', 16);
      bytes[i * 2] = (val >> 8) & 0xff;
      bytes[i * 2 + 1] = val & 0xff;
    }
  }

  return bytes;
}

/**
 * SOCKS5 错误代码描述映射
 */
function getSocks5ErrorMessage(code) {
  switch (code) {
    case 0x01: return 'General SOCKS server failure';
    case 0x02: return 'Connection not allowed by ruleset';
    case 0x03: return 'Network unreachable';
    case 0x04: return 'Host unreachable';
    case 0x05: return 'Connection refused';
    case 0x06: return 'TTL expired';
    case 0x07: return 'Command not supported';
    case 0x08: return 'Address type not supported';
    default: return `Unknown error (${code})`;
  }
}

/**
 * 针对原生 OpenVPN TCP 端口进行协议层握手连通性与 RTT 延迟探测
 */
async function testOpenVpnDirect(proxy, timeoutMs = 8000) {
  const start = Date.now();
  const connect = await getConnectFn();
  const socket = connect({
    hostname: proxy.host,
    port: proxy.port,
  });

  const reader = socket.readable.getReader();
  const writer = socket.writable.getWriter();

  try {
    // 构造 OpenVPN P_CONTROL_HARD_RESET_CLIENT_V2 TCP 报文 (16 字节)
    const payloadLen = 14;
    const packet = new Uint8Array(16);
    packet[0] = (payloadLen >> 8) & 0xff;
    packet[1] = payloadLen & 0xff;
    packet[2] = 0x38; // Opcode 7 (P_CONTROL_HARD_RESET_CLIENT_V2) << 3
    crypto.getRandomValues(packet.subarray(3, 11)); // 8 字节随机 Session ID
    packet[11] = 0;
    packet[12] = 0;
    packet[13] = 0;
    packet[14] = 0;
    packet[15] = 0;

    await writer.write(packet);

    const readPromise = reader.read();
    const timeoutPromise = new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`OpenVPN 握手响应超时 (${timeoutMs / 1000}s)`)), timeoutMs)
    );

    const { value, done } = await Promise.race([readPromise, timeoutPromise]);
    const latency = Date.now() - start;

    if (done || !value || value.length < 3) {
      throw new Error('未收到有效的 OpenVPN 服务端响应报文');
    }

    const respOpcode = value[2] >> 3;
    // 8: P_CONTROL_HARD_RESET_SERVER_V2, 5: P_ACK_V1, 7: P_CONTROL_HARD_RESET_CLIENT_V2, 0x16: TLS ServerHello
    const isValid = respOpcode === 8 || respOpcode === 5 || respOpcode === 7 || value[0] === 0x16 || value[2] === 0x16;

    if (!isValid) {
      throw new Error(`收到非 OpenVPN 协议响应 (Opcode: ${respOpcode})`);
    }

    return {
      success: true,
      latencyMs: latency,
      message: `OpenVPN 原生节点探测成功！类型: OPENVPN (TCP), 握手延迟: ${latency}ms, 目标节点: ${proxy.host}:${proxy.port}`,
    };
  } finally {
    try { reader.releaseLock(); } catch (_) {}
    try { writer.releaseLock(); } catch (_) {}
    try { socket.close(); } catch (_) {}
  }
}

/**
 * 测试上游代理可用性与延迟（连接到测试目标 www.google.com:443 或执行原生 OpenVPN 握手）
 * @param {string} proxyString 代理配置
 * @param {number} timeoutMs 超时时间（默认 8000ms）
 * @returns {Promise<{ success: boolean, latencyMs?: number, message: string }>}
 */
export async function testUpstreamProxy(proxyString, timeoutMs = 8000) {
  const start = Date.now();
  try {
    const proxy = parseProxyString(proxyString);
    if (!proxy) {
      return { success: false, message: '无法解析代理配置格式，请检查语法' };
    }

    let testExecution;
    if (proxy.protocol === 'openvpn' || proxy.protocol === 'ovpn') {
      testExecution = testOpenVpnDirect(proxy, timeoutMs);
    } else {
      testExecution = (async () => {
        // 使用 443 (HTTPS) 作为探测目标，满足 HTTP 代理对 CONNECT 必须为 SSL/443 安全端口的规范
        const { socket } = await createUpstreamConnection('www.google.com', 443, proxyString, false);
        const latency = Date.now() - start;

        try {
          socket.close();
        } catch (_) {}

        return {
          success: true,
          latencyMs: latency,
          message: `代理握手成功！类型: ${proxy.protocol.toUpperCase()}, 延迟: ${latency}ms, 代理服务器: ${proxy.host}:${proxy.port}`,
        };
      })();
    }

    const timeoutExecution = new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`握手超时 (${timeoutMs / 1000}s)，代理服务器未响应或连接受阻`)), timeoutMs)
    );

    return await Promise.race([testExecution, timeoutExecution]);
  } catch (err) {
    return {
      success: false,
      message: `代理连接测试失败: ${err.message}`,
    };
  }
}

