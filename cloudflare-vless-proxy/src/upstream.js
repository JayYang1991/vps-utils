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
 * 解析各种格式的代理字符串
 * 支持格式：
 * 1. socks5://user:pass@host:port
 * 2. socks5://host:port
 * 3. http://user:pass@host:port
 * 4. http://host:port
 * 5. user:pass@host:port (默认为 socks5)
 * 6. host:port:user:pass (默认为 socks5)
 * 7. host:port (默认为 socks5)
 * @param {string} rawProxy
 * @returns {object|null}
 */
export function parseProxyString(rawProxy) {
  if (!rawProxy || typeof rawProxy !== 'string') return null;
  const str = rawProxy.trim();
  if (!str) return null;

  try {
    // 包含协议头的情况
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

    // host:port:user:pass 格式
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

    // user:pass@host:port 格式
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

    // host:port 格式
    if (parts.length === 2) {
      return {
        protocol: 'socks5',
        host: parts[0].trim(),
        port: parseInt(parts[1].trim(), 10),
        username: '',
        password: '',
      };
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
    const connect = await getConnectFn();
    const socket = connect({
      hostname: targetHost,
      port: targetPort,
    });
    return { socket };
  }

  // 通过住宅代理转发
  try {
    if (proxy.protocol === 'socks5') {
      return await connectViaSocks5(proxy, targetHost, targetPort);
    } else if (proxy.protocol === 'http') {
      return await connectViaHttpConnect(proxy, targetHost, targetPort);
    } else {
      throw new Error(`Unsupported proxy protocol: ${proxy.protocol}`);
    }
  } catch (proxyErr) {
    console.error(`Residential proxy [${proxy.protocol}://${proxy.host}:${proxy.port}] connection failed:`, proxyErr.message);
    if (enableFallback) {
      console.log(`Falling back to direct connection for ${targetHost}:${targetPort}`);
      const connect = await getConnectFn();
      const socket = connect({
        hostname: targetHost,
        port: targetPort,
      });
      return { socket };
    }
    throw proxyErr;
  }
}

/**
 * 通过 SOCKS5 代理连接目标主机
 */
async function connectViaSocks5(proxy, targetHost, targetPort) {
  const connect = await getConnectFn();
  const socket = connect({
    hostname: proxy.host,
    port: proxy.port,
  });

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
      throw new Error(`Invalid SOCKS5 version response: ${greetingRes[0]}`);
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
  const socket = connect({
    hostname: proxy.host,
    port: proxy.port,
  });

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

    while (headerEndIndex === -1) {
      const { value, done } = await reader.read();
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
 * 精确从 Reader 中读取指定长度的字节
 */
async function readExactBytes(reader, length) {
  const result = new Uint8Array(length);
  let offset = 0;

  while (offset < length) {
    const { value, done } = await reader.read();
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
      // 注意：由于 reader.read() 流式特性，握手阶段多余字节通常不会出现，
      // 若出现会被丢弃；对于 CONNECT 复杂情况在 HTTP 中单独处理。
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
 * 测试上游代理可用性与延迟（连接到测试目标 cloudflare.com:80）
 * @param {string} proxyString 代理配置
 * @returns {Promise<{ success: boolean, latencyMs?: number, message: string }>}
 */
export async function testUpstreamProxy(proxyString) {
  const start = Date.now();
  try {
    const proxy = parseProxyString(proxyString);
    if (!proxy) {
      return { success: false, message: '无法解析代理配置格式，请检查语法' };
    }

    const { socket } = await createUpstreamConnection('1.1.1.1', 80, proxyString, false);
    const latency = Date.now() - start;

    try {
      socket.close();
    } catch (_) {}

    return {
      success: true,
      latencyMs: latency,
      message: `代理握手成功！类型: ${proxy.protocol.toUpperCase()}, 延迟: ${latency}ms, 主机: ${proxy.host}:${proxy.port}`,
    };
  } catch (err) {
    return {
      success: false,
      message: `代理连接测试失败: ${err.message}`,
    };
  }
}
