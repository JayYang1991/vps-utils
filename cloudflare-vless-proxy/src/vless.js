import { createUpstreamConnection } from './upstream.js';
import { renderLandingPage } from './landing.js';

/**
 * 处理 VLESS WebSocket 代理请求
 * @param {Request} request 
 * @param {object} config 
 * @returns {Response}
 */
export async function handleVlessWebSocket(request, config) {
  const clientIp = request.headers.get('cf-connecting-ip') || request.headers.get('x-real-ip') || 'unknown';
  const upgradeHeader = request.headers.get('Upgrade');
  
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    console.warn(`[VLESS:WS] Received non-WebSocket request on proxy path from IP: ${clientIp}`);
    return new Response(renderLandingPage(), {
      status: 200,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  // 支持 Early Data (由客户端通过 Sec-WebSocket-Protocol 携带 Base64 编码的初始数据)
  let earlyDataHeader = request.headers.get('sec-websocket-protocol');
  let preDecodedEarlyData = null;

  // 若携带 Early Data，提前校验 VLESS UUID 鉴权；若鉴权失败直接退回静态落地页
  if (earlyDataHeader) {
    try {
      preDecodedEarlyData = base64UrlToUint8Array(earlyDataHeader);
      const earlyCheck = parseVlessHeader(preDecodedEarlyData, config.uuid);
      if (!earlyCheck.success) {
        console.error(`[VLESS:Auth:EarlyData] UUID 鉴权失败 (来自 IP: ${clientIp}): ${earlyCheck.error} (配置 UUID: ${config.uuid})`);
        return new Response(renderLandingPage(), {
          status: 200,
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      }
      console.log(`[VLESS:Auth:EarlyData] EarlyData 校验通过 (来自 IP: ${clientIp}, 目标: ${earlyCheck.address}:${earlyCheck.port})`);
    } catch (e) {
      console.error(`[VLESS:EarlyData:Error] 解析 Early-Data 协议头异常 (来自 IP: ${clientIp}):`, e.message || e);
      return new Response(renderLandingPage(), {
        status: 200,
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      });
    }
  }

  const clientInfo = {
    ip: clientIp,
    ua: request.headers.get('user-agent') || 'none',
    url: request.url,
  };

  const webSocketPair = new WebSocketPair();
  const [clientWs, serverWs] = Object.values(webSocketPair);

  serverWs.accept();
  console.log(`[VLESS:WS] WebSocket 握手成功 (Client IP: ${clientIp}, EarlyData: ${!!preDecodedEarlyData})`);

  // 异步处理 VLESS 会话
  processVlessSession(serverWs, preDecodedEarlyData, config, clientInfo).catch((err) => {
    console.error(`[VLESS:Session:Fatal] 会话未捕获异常 (IP: ${clientIp}):`, err.stack || err.message || err);
    safeCloseWebSocket(serverWs);
  });

  return new Response(null, {
    status: 101,
    webSocket: clientWs,
    headers: earlyDataHeader ? { 'Sec-WebSocket-Protocol': earlyDataHeader } : undefined,
  });
}

/**
 * 处理 VLESS 会话生命周期
 */
async function processVlessSession(ws, earlyData, config, clientInfo = {}) {
  let isHeaderParsed = false;
  let remoteSocket = null;
  let remoteWriter = null;
  let targetAddress = '';
  let targetPort = 0;
  const clientIp = clientInfo.ip || 'unknown';

  // 辅助关闭连接
  const cleanup = () => {
    if (remoteWriter) {
      try { remoteWriter.releaseLock(); } catch (_) {}
    }
    if (remoteSocket) {
      try { remoteSocket.close(); } catch (_) {}
    }
    safeCloseWebSocket(ws);
  };

  // 处理从 WebSocket 接收到的二进制数据
  const handleClientData = async (data) => {
    try {
      const buffer = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(await data.arrayBuffer());

      if (!isHeaderParsed) {
        // 解析 VLESS 首包
        const parseResult = parseVlessHeader(buffer, config.uuid);
        if (!parseResult.success) {
          console.error(`[VLESS:Header:Error] VLESS 请求头校验失败 (IP: ${clientIp}): ${parseResult.error} | 服务端配置 UUID: ${config.uuid}`);
          cleanup();
          return;
        }

        isHeaderParsed = true;
        targetAddress = parseResult.address;
        targetPort = parseResult.port;

        console.log(`[VLESS:Connect] 开始建立上游连接 -> 目标: ${targetAddress}:${targetPort} (命令: ${parseResult.command === 1 ? 'TCP' : 'UDP'}, 上游模式: ${config.upstreamProxy ? '住宅代理中继' : '边缘直连'})`);

        // 连接目标或住宅代理
        let connResult;
        try {
          connResult = await createUpstreamConnection(
            targetAddress,
            targetPort,
            config.upstreamProxy,
            config.enableDirectFallback
          );
        } catch (connErr) {
          console.error(`[VLESS:Upstream:Fail] 建立上游连接失败 [${targetAddress}:${targetPort}] (IP: ${clientIp}): ${connErr.message}`);
          cleanup();
          return;
        }

        const { socket, initialBuffer } = connResult;
        remoteSocket = socket;
        remoteWriter = remoteSocket.writable.getWriter();

        console.log(`[VLESS:Connected] 上游 Socket 连接成功 [${targetAddress}:${targetPort}]，开始向客户端回送响应`);

        // 向客户端回送 VLESS 响应头 (Version: 0x00, Addon Len: 0x00)
        const vlessResponseHeader = new Uint8Array([parseResult.version, 0x00]);

        // 如果 HTTP 握手有额外残留数据，合并在响应中
        if (initialBuffer && initialBuffer.length > 0) {
          const combined = new Uint8Array(vlessResponseHeader.length + initialBuffer.length);
          combined.set(vlessResponseHeader, 0);
          combined.set(initialBuffer, vlessResponseHeader.length);
          ws.send(combined);
        } else {
          ws.send(vlessResponseHeader);
        }

        // 启动从远端 Socket 读取并回传给 WebSocket 的管道
        pipeRemoteToWebSocket(remoteSocket, ws, cleanup, targetAddress, targetPort);

        // 如果首包中包含初始载荷 (Payload)，写入远端 Socket
        if (parseResult.payload && parseResult.payload.length > 0) {
          await remoteWriter.write(parseResult.payload);
        }
      } else {
        // 后续数据直接写入远端 Socket
        if (remoteWriter) {
          await remoteWriter.write(buffer);
        }
      }
    } catch (err) {
      console.error(`[VLESS:Stream:Error] 数据转发流异常 [${targetAddress}:${targetPort}] (IP: ${clientIp}):`, err.message || err);
      cleanup();
    }
  };

  // 1. 如果存在 earlyData，优先解析处理
  if (earlyData) {
    try {
      const decodedEarly = earlyData instanceof Uint8Array ? earlyData : base64UrlToUint8Array(earlyData);
      await handleClientData(decodedEarly);
    } catch (e) {
      console.error(`[VLESS:EarlyData:Error] 处理 Early-Data 数据异常 (IP: ${clientIp}):`, e.message || e);
    }
  }

  // 2. 监听 WebSocket 消息事件
  ws.addEventListener('message', async (event) => {
    await handleClientData(event.data);
  });

  ws.addEventListener('close', (event) => {
    console.log(`[VLESS:WS:Close] 客户端断开连接 (IP: ${clientIp}, 目标: ${targetAddress}:${targetPort}, Code: ${event.code})`);
    cleanup();
  });

  ws.addEventListener('error', (err) => {
    console.error(`[VLESS:WS:Error] WebSocket 异常 (IP: ${clientIp}, 目标: ${targetAddress}:${targetPort}):`, err.message || err);
    cleanup();
  });
}

/**
 * 将远端 Socket 的可读流传输至 WebSocket 客户端
 */
async function pipeRemoteToWebSocket(remoteSocket, ws, cleanup, targetAddress, targetPort) {
  let reader = null;
  try {
    reader = remoteSocket.readable.getReader();
    while (true) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }
      if (value && value.length > 0) {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(value);
        } else {
          break;
        }
      }
    }
  } catch (err) {
    console.error(`[VLESS:Pipe:Error] 远端到客户端转发异常 [${targetAddress}:${targetPort}]:`, err.message || err);
  } finally {
    if (reader) {
      try { reader.releaseLock(); } catch (_) {}
    }
    cleanup();
  }
}

/**
 * 解析 VLESS 请求头部
 * @param {Uint8Array} buffer 
 * @param {string} expectedUUID 
 */
export function parseVlessHeader(buffer, expectedUUID) {
  if (!buffer || buffer.length < 24) {
    return { success: false, error: 'Packet too short for VLESS header' };
  }

  const version = buffer[0];

  // 提取 16 字节 UUID
  const clientUUID = bytesToUUID(buffer.subarray(1, 17));
  const normalizedExpected = (expectedUUID || '').toLowerCase().trim();

  if (clientUUID.toLowerCase() !== normalizedExpected) {
    return {
      success: false,
      error: `UUID mismatch. Got: ${clientUUID}, Expected: ${normalizedExpected}`,
    };
  }

  const addonLength = buffer[17];
  let cursor = 18 + addonLength;

  if (cursor >= buffer.length) {
    return { success: false, error: 'Malformed VLESS header (addon overflow)' };
  }

  const command = buffer[cursor]; // 1 = TCP, 2 = UDP, 3 = MUX
  cursor += 1;

  if (command !== 1 && command !== 2) {
    return { success: false, error: `Unsupported VLESS command: ${command}` };
  }

  const port = (buffer[cursor] << 8) | buffer[cursor + 1];
  cursor += 2;

  const addressType = buffer[cursor];
  cursor += 1;

  let address = '';

  if (addressType === 1) {
    // IPv4 (4 bytes)
    if (cursor + 4 > buffer.length) return { success: false, error: 'Malformed IPv4 address' };
    address = `${buffer[cursor]}.${buffer[cursor + 1]}.${buffer[cursor + 2]}.${buffer[cursor + 3]}`;
    cursor += 4;
  } else if (addressType === 2) {
    // Domain (1 byte length + domain characters)
    if (cursor + 1 > buffer.length) return { success: false, error: 'Malformed domain address' };
    const domainLen = buffer[cursor];
    cursor += 1;
    if (cursor + domainLen > buffer.length) return { success: false, error: 'Domain length overflow' };
    address = new TextDecoder().decode(buffer.subarray(cursor, cursor + domainLen));
    cursor += domainLen;
  } else if (addressType === 3) {
    // IPv6 (16 bytes)
    if (cursor + 16 > buffer.length) return { success: false, error: 'Malformed IPv6 address' };
    const ipv6Parts = [];
    for (let i = 0; i < 8; i++) {
      const val = (buffer[cursor + i * 2] << 8) | buffer[cursor + i * 2 + 1];
      ipv6Parts.push(val.toString(16));
    }
    address = ipv6Parts.join(':');
    cursor += 16;
  } else {
    return { success: false, error: `Unknown address type: ${addressType}` };
  }

  const payload = buffer.subarray(cursor);

  return {
    success: true,
    version,
    command,
    port,
    address,
    addressType,
    payload,
  };
}

/**
 * 将 16 字节转为标准 UUID 字符串
 */
export function bytesToUUID(bytes) {
  const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

/**
 * Base64Url 解码为 Uint8Array
 */
function base64UrlToUint8Array(base64Str) {
  let base64 = base64Str.replace(/-/g, '+').replace(/_/g, '/');
  while (base64.length % 4) base64 += '=';
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * 安全关闭 WebSocket
 */
function safeCloseWebSocket(ws) {
  try {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
      ws.close(1000, 'Session terminated');
    }
  } catch (_) {}
}
