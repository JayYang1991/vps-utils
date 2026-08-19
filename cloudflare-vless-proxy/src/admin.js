/**
 * Admin Management Panel & API Endpoints
 * Includes Clash & Sing-box Subscriptions, Dynamic Preferred IPs, VLESS Links, and Built-in QR Code Generator.
 */

import { getConfig, saveConfig, verifyAdminAuth, hashPassword, DEFAULT_CONFIG_URL, DEFAULT_SINGBOX_CONFIG_URL } from './config.js';
import { testUpstreamProxy } from './upstream.js';
import { generateAllVlessNodes, generateSingboxConfig, generateClashMetaConfig, fetchSubconfigs, clearPreferredNodesCache } from './sub.js';

/**
 * 处理管理后台的所有 HTTP 请求
 * @param {Request} request 
 * @param {object} env 
 * @param {URL} url 
 * @param {object} config 
 */
export async function handleAdmin(request, env, url, config) {
  const path = url.pathname;
  const method = request.method;

  // 1. API: 登录接口 (POST /admin/api/login)
  if (path.endsWith('/api/login') && method === 'POST') {
    return handleLogin(request, config);
  }

  // 2. API: 获取远程规则列表 (GET /admin/api/subconfigs)
  if (path.endsWith('/api/subconfigs') && method === 'GET') {
    const configs = await fetchSubconfigs();
    return jsonResponse(configs);
  }

  // 3. API: 刷新优选 IP 节点缓存 (POST /admin/api/refresh-ip)
  if (path.endsWith('/api/refresh-ip') && method === 'POST') {
    const isAuthed = await verifyAdminAuth(request, config);
    if (!isAuthed) {
      return jsonResponse({ error: 'Unauthorized' }, 401);
    }
    clearPreferredNodesCache();
    const workerDomain = url.host;
    const nodes = await generateAllVlessNodes(config, workerDomain, { forceRefresh: true, env });
    return jsonResponse({ success: true, message: '优选 IP 节点已刷新！', count: nodes.length, nodes });
  }

  // 4. API: 获取配置、节点与订阅链接 (GET /admin/api/config)
  if (path.endsWith('/api/config') && method === 'GET') {
    const isAuthed = await verifyAdminAuth(request, config);
    if (!isAuthed) {
      return jsonResponse({ error: 'Unauthorized' }, 401);
    }
    const workerDomain = url.host;
    const token = await hashPassword(config.adminPassword);
    const nodes = await generateAllVlessNodes(config, workerDomain, { env });
    const singbox = generateSingboxConfig(nodes, config, workerDomain);
    const clash = generateClashMetaConfig(nodes, config, workerDomain);

    const subscriptions = {
      adaptive: `${url.origin}/sub?token=${token}`,
      clash: `${url.origin}/clash?token=${token}`,
      singbox: `${url.origin}/singbox?token=${token}`,
      vless: `${url.origin}/v2ray?token=${token}`,
    };

    const restApi = {
      endpoint: `${url.origin}/api/upstream`,
      testEndpoint: `${url.origin}/api/upstream/test`,
      apiToken: config.apiToken,
    };

    return jsonResponse({
      config: {
        uuid: config.uuid,
        proxyPath: config.proxyPath,
        adminPath: config.adminPath,
        apiToken: config.apiToken,
        upstreamProxy: config.upstreamProxy,
        cleanIPs: config.cleanIPs,
        nodeName: config.nodeName,
        enableDirectFallback: config.enableDirectFallback,
        configUrl: config.configUrl || DEFAULT_CONFIG_URL,
        singboxConfigUrl: config.singboxConfigUrl || DEFAULT_SINGBOX_CONFIG_URL,
        preferredSubUrl: config.preferredSubUrl || PREFERRED_SUB_URL,
        subapiUrl: config.subapiUrl || SUBAPI_URL,
      },
      kvEnabled: !!env.CONFIG_KV,
      workerDomain,
      nodes,
      singbox,
      clash,
      subscriptions,
      restApi,
    });
  }

  // 4.1 API: 生成新随机 API Token (POST /admin/api/generate-token)
  if (path.endsWith('/api/generate-token') && method === 'POST') {
    const isAuthed = await verifyAdminAuth(request, config);
    if (!isAuthed) {
      return jsonResponse({ error: 'Unauthorized' }, 401);
    }
    const bytes = new Uint8Array(20);
    crypto.getRandomValues(bytes);
    const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
    const newToken = `cf-push-${hex}`;
    return jsonResponse({ success: true, apiToken: newToken });
  }

  // 5. API: 保存配置 (POST /admin/api/config)
  if (path.endsWith('/api/config') && method === 'POST') {
    const isAuthed = await verifyAdminAuth(request, config);
    if (!isAuthed) {
      return jsonResponse({ error: 'Unauthorized' }, 401);
    }
    try {
      const body = await request.json();
      const next = await saveConfig(env, body);
      return jsonResponse({ success: true, message: '配置已成功更新至 KV！', config: next });
    } catch (err) {
      return jsonResponse({ error: err.message }, 500);
    }
  }

  // 6. API: 测试住宅代理 (POST /admin/api/test-upstream)
  if (path.endsWith('/api/test-upstream') && method === 'POST') {
    const isAuthed = await verifyAdminAuth(request, config);
    if (!isAuthed) {
      return jsonResponse({ error: 'Unauthorized' }, 401);
    }
    try {
      const body = await request.json();
      const result = await testUpstreamProxy(body.upstreamProxy || config.upstreamProxy);
      return jsonResponse(result);
    } catch (err) {
      return jsonResponse({ success: false, message: err.message }, 500);
    }
  }

  // 7. 前端单页面 HTML (GET /admin)
  if (method === 'GET') {
    return new Response(getAdminHTML(url.host, config.adminPath), {
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  return new Response('Not Found', { status: 404 });
}

/**
 * 登录处理
 */
async function handleLogin(request, config) {
  try {
    const { password } = await request.json();
    if (password === config.adminPassword) {
      const token = await hashPassword(config.adminPassword);
      return new Response(JSON.stringify({ success: true, token }), {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': `admin_token=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400`,
        },
      });
    }
    return jsonResponse({ success: false, message: '密码错误，请重试' }, 401);
  } catch (err) {
    return jsonResponse({ success: false, message: '请求参数错误' }, 400);
  }
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

/**
 * 渲染管理员控制台 SPA HTML（内建纯原生 JS 二维码生成引擎）
 */
function getAdminHTML(host, adminPath) {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>VLESS 住宅代理网关控制台</title>
  <style>
    :root {
      --bg: #0b1120;
      --card-bg: #151f32;
      --card-border: #233554;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --primary: #3b82f6;
      --primary-hover: #2563eb;
      --success: #10b981;
      --danger: #ef4444;
      --warning: #f59e0b;
      --input-bg: #090d16;
      --input-border: #334155;
      --radius: 8px;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
      padding: 20px;
    }
    .container { max-width: 1040px; margin: 0 auto; }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--card-border);
      margin-bottom: 24px;
    }
    .header h1 { font-size: 1.35rem; display: flex; align-items: center; gap: 8px; }
    .status-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 0.8rem;
      padding: 4px 10px;
      border-radius: 9999px;
      background: rgba(16, 185, 129, 0.15);
      color: var(--success);
      border: 1px solid rgba(16, 185, 129, 0.3);
    }
    .btn {
      background: var(--primary);
      color: #fff;
      border: none;
      padding: 8px 14px;
      border-radius: var(--radius);
      cursor: pointer;
      font-weight: 500;
      transition: all 0.2s;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 0.88rem;
    }
    .btn:hover { background: var(--primary-hover); }
    .btn-secondary { background: #233554; color: #f8fafc; }
    .btn-secondary:hover { background: #334b75; }
    .btn-success { background: var(--success); }
    .btn-success:hover { background: #059669; }
    .btn-sm { padding: 4px 10px; font-size: 0.8rem; }
    .btn-danger { background: var(--danger); }
    
    .tabs { display: flex; gap: 8px; margin-bottom: 20px; border-bottom: 1px solid var(--card-border); }
    .tab {
      padding: 10px 18px;
      cursor: pointer;
      border-bottom: 2px solid transparent;
      color: var(--text-muted);
      font-weight: 500;
    }
    .tab.active { color: var(--primary); border-bottom-color: var(--primary); }

    .card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: var(--radius);
      padding: 20px;
      margin-bottom: 20px;
    }
    .card-title { font-size: 1.08rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; }
    
    .form-group { margin-bottom: 16px; }
    .form-label { display: block; font-size: 0.85rem; color: var(--text-muted); margin-bottom: 6px; }
    .form-control {
      width: 100%;
      background: var(--input-bg);
      border: 1px solid var(--input-border);
      color: var(--text);
      padding: 10px 12px;
      border-radius: var(--radius);
      font-size: 0.95rem;
      outline: none;
      font-family: inherit;
    }
    .form-control:focus { border-color: var(--primary); }
    textarea.form-control { resize: vertical; min-height: 80px; font-family: monospace; font-size: 0.85rem; }
    
    .input-with-action { display: flex; gap: 8px; }
    .help-text { font-size: 0.75rem; color: var(--text-muted); margin-top: 5px; }

    .sub-item {
      background: #090d16;
      border: 1px solid var(--card-border);
      border-radius: var(--radius);
      padding: 14px;
      margin-bottom: 12px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .sub-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .sub-name { font-weight: 600; font-size: 0.95rem; display: flex; align-items: center; gap: 6px; }
    .sub-url-row {
      display: flex;
      gap: 8px;
      align-items: center;
    }

    .node-item {
      background: #090d16;
      border: 1px solid var(--card-border);
      border-radius: var(--radius);
      padding: 12px 16px;
      margin-bottom: 10px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
    }
    .node-info { overflow: hidden; }
    .node-name { font-weight: 600; font-size: 0.95rem; margin-bottom: 4px; }
    .node-url { font-size: 0.75rem; color: var(--text-muted); word-break: break-all; }

    .code-block {
      background: #090d16;
      border: 1px solid var(--card-border);
      border-radius: var(--radius);
      padding: 14px;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.82rem;
      color: #38bdf8;
      overflow-x: auto;
      white-space: pre-wrap;
      word-break: break-all;
    }

    /* 登录弹窗 */
    #login-overlay {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: rgba(11, 17, 32, 0.92);
      backdrop-filter: blur(8px);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 9999;
    }
    .login-box {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      padding: 32px;
      border-radius: 12px;
      width: 100%;
      max-width: 380px;
      text-align: center;
    }

    /* 二维码弹窗 */
    #qr-modal {
      display: none;
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: rgba(0, 0, 0, 0.75);
      backdrop-filter: blur(4px);
      z-index: 10001;
      align-items: center;
      justify-content: center;
    }
    .qr-card {
      background: #fff;
      color: #0f172a;
      padding: 24px;
      border-radius: 16px;
      text-align: center;
      max-width: 360px;
      width: 90%;
      box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.5);
      position: relative;
    }
    .qr-close {
      position: absolute;
      top: 12px;
      right: 16px;
      background: transparent;
      border: none;
      font-size: 1.5rem;
      color: #64748b;
      cursor: pointer;
    }
    .qr-canvas-container {
      margin: 16px auto;
      display: flex;
      justify-content: center;
      align-items: center;
      background: #fff;
      padding: 10px;
      border-radius: 8px;
    }
    .qr-title { font-size: 1.1rem; font-weight: 700; margin-bottom: 6px; word-break: break-all; }
    .qr-text-preview {
      font-size: 0.75rem;
      color: #64748b;
      word-break: break-all;
      max-height: 60px;
      overflow-y: auto;
      background: #f1f5f9;
      padding: 8px;
      border-radius: 6px;
      margin-top: 10px;
      text-align: left;
    }

    /* Toast 通知 */
    #toast {
      position: fixed;
      bottom: 24px;
      right: 24px;
      padding: 12px 20px;
      border-radius: var(--radius);
      background: #1e293b;
      color: #fff;
      border: 1px solid var(--card-border);
      box-shadow: 0 10px 15px -3px rgba(0,0,0,0.5);
      transform: translateY(100px);
      opacity: 0;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
      z-index: 10000;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    #toast.show { transform: translateY(0); opacity: 1; }
    #toast.success { border-color: var(--success); color: var(--success); }
    #toast.error { border-color: var(--danger); color: var(--danger); }

    .test-result-box {
      margin-top: 10px;
      padding: 10px 14px;
      border-radius: var(--radius);
      font-size: 0.85rem;
      display: none;
    }
    .test-result-box.success { display: block; background: rgba(16, 185, 129, 0.1); border: 1px solid var(--success); color: var(--success); }
    .test-result-box.error { display: block; background: rgba(239, 68, 68, 0.1); border: 1px solid var(--danger); color: var(--danger); }
  </style>
</head>
<body>

  <!-- 登录弹窗 -->
  <div id="login-overlay">
    <div class="login-box">
      <h2 style="margin-bottom: 8px;">🔐 管理员登录</h2>
      <p style="font-size: 0.85rem; color: var(--text-muted); margin-bottom: 20px;">请输入 Cloudflare Worker 管理密码</p>
      <div class="form-group">
        <input type="password" id="login-pass" class="form-control" placeholder="输入管理密码..." onkeydown="if(event.key==='Enter') doLogin()">
      </div>
      <button id="btn-do-login" class="btn" style="width: 100%; justify-content: center;" onclick="doLogin()">登 录</button>
      <div id="login-error-msg" style="margin-top: 12px; font-size: 0.85rem; color: #ef4444; background: rgba(239, 68, 68, 0.1); border: 1px solid rgba(239, 68, 68, 0.2); padding: 8px 12px; border-radius: 6px; display: none;"></div>
      <p style="margin-top: 16px; font-size: 0.78rem; color: var(--text-muted); text-align: center; border-top: 1px solid var(--card-border); padding-top: 12px;">
        💡 初始默认密码为 <code>test1234!</code><br>(可于 wrangler.toml 或 KV 中自定义修改)
      </p>
    </div>
  </div>

  <!-- 二维码展示弹窗 -->
  <div id="qr-modal" onclick="if(event.target===this) closeQRModal()">
    <div class="qr-card">
      <button class="qr-close" onclick="closeQRModal()">&times;</button>
      <div class="qr-title" id="qr-modal-title">扫描二维码</div>
      <div class="qr-canvas-container" id="qr-container"></div>
      <div class="qr-text-preview" id="qr-modal-text"></div>
      <button class="btn btn-sm btn-secondary" style="margin-top: 12px; width: 100%; justify-content: center;" onclick="copyCurrentQRText()">📋 复制文本内容</button>
    </div>
  </div>

  <div class="container" id="app-container" style="display:none;">
    <div class="header">
      <div>
        <h1>⚡ VLESS 住宅代理网关控制台</h1>
        <div style="font-size: 0.85rem; color: var(--text-muted); margin-top: 4px;">
          当前服务节点: <span id="lbl-domain" style="color: var(--primary);"></span>
        </div>
      </div>
      <div style="display: flex; gap: 10px; align-items: center;">
        <span class="status-badge" id="kv-status">● KV 持久化就绪</span>
        <button class="btn btn-secondary btn-sm" onclick="doLogout()">退出</button>
      </div>
    </div>

    <!-- 选项卡导航 -->
    <div class="tabs">
      <div class="tab active" onclick="switchTab('tab-sub')">🔗 订阅与节点导出</div>
      <div class="tab" onclick="switchTab('tab-config')">⚙️ 代理路径与住宅IP配置</div>
      <div class="tab" onclick="switchTab('tab-client')">📱 客户端配置片段</div>
    </div>

    <!-- TAB 1: 订阅与节点导出 -->
    <div id="tab-sub" class="tab-pane">
      
      <!-- 客户端聚合订阅 -->
      <div class="card">
        <div class="card-title">
          <span>🔗 客户端开箱即用聚合订阅</span>
        </div>

        <!-- 转换规则配置文件下拉选择 -->
        <div class="form-group" style="margin-bottom: 18px; padding: 12px 14px; background: #090d16; border-radius: var(--radius); border: 1px solid var(--card-border);">
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom: 8px;">
            <label class="form-label" style="margin-bottom:0; font-weight:600; color:#38bdf8;">🎯 转换规则配置文件 (SUBCONFIG)</label>
            <span id="cfg-status-tip" style="font-size:0.75rem; color:var(--success);">已保存至服务端</span>
          </div>
          <select id="cfg-subconfig-select" class="form-control" onchange="handleSubconfigChange()">
            <option value="https://raw.githubusercontent.com/JayYang1991/ACL4SSR/refs/heads/main/Clash/config/ACL4SSR_Online_Bespoke.ini">🔥 默认规则: ACL4SSR_Online_Bespoke (自定义精细化分流规则)</option>
          </select>
        </div>

        <!-- 智能自适应订阅 -->
        <div class="sub-item" style="border: 1px solid rgba(59, 130, 246, 0.4); background: rgba(59, 130, 246, 0.05);">
          <div class="sub-header">
            <span class="sub-name" style="color: #60a5fa;">✨ 智能自适应订阅 (推荐首选)</span>
            <span style="font-size:0.75rem; color:var(--text-muted);">自动识别客户端 User-Agent (Clash / sing-box / V2Ray)</span>
          </div>
          <div class="sub-url-row">
            <input type="text" id="sub-adaptive-url" class="form-control" readonly>
            <button class="btn btn-secondary btn-sm" onclick="copyInputText('sub-adaptive-url')">复制</button>
            <button class="btn btn-sm" onclick="showQRModal('智能自适应订阅', document.getElementById('sub-adaptive-url').value)">📱 二维码</button>
          </div>
        </div>
        
        <!-- Clash Meta 订阅 -->
        <div class="sub-item">
          <div class="sub-header">
            <span class="sub-name">🐱 Clash Meta / Mihomo 完整订阅</span>
            <span style="font-size:0.75rem; color:var(--text-muted);">通过 subapi.19910417.xyz 在线规则转换</span>
          </div>
          <div class="sub-url-row">
            <input type="text" id="sub-clash-url" class="form-control" readonly>
            <button class="btn btn-secondary btn-sm" onclick="copyInputText('sub-clash-url')">复制</button>
            <button class="btn btn-sm" onclick="showQRModal('Clash Meta 订阅', document.getElementById('sub-clash-url').value)">📱 二维码</button>
          </div>
        </div>

        <!-- Sing-box 订阅 -->
        <div class="sub-item">
          <div class="sub-header">
            <span class="sub-name">📦 Sing-box 完整配置订阅</span>
            <span style="font-size:0.75rem; color:var(--text-muted);">开箱即用 JSON 规则转换配置</span>
          </div>
          <div class="sub-url-row">
            <input type="text" id="sub-singbox-url" class="form-control" readonly>
            <button class="btn btn-secondary btn-sm" onclick="copyInputText('sub-singbox-url')">复制</button>
            <button class="btn btn-sm" onclick="showQRModal('Sing-box 订阅', document.getElementById('sub-singbox-url').value)">📱 二维码</button>
          </div>
        </div>

        <!-- 通用 Base64 订阅 -->
        <div class="sub-item">
          <div class="sub-header">
            <span class="sub-name">🚀 通用 VLESS Base64 订阅</span>
            <span style="font-size:0.75rem; color:var(--text-muted);">适用于 V2rayN / Shadowrocket / Quantumult X</span>
          </div>
          <div class="sub-url-row">
            <input type="text" id="sub-vless-url" class="form-control" readonly>
            <button class="btn btn-secondary btn-sm" onclick="copyInputText('sub-vless-url')">复制</button>
            <button class="btn btn-sm" onclick="showQRModal('通用 VLESS 订阅', document.getElementById('sub-vless-url').value)">📱 二维码</button>
          </div>
        </div>
      </div>

      <!-- VLESS 单节点列表 -->
      <div class="card">
        <div class="card-title">
          <div>
            <span>📋 VLESS 优选 IP 节点列表 (<span id="lbl-node-count">0</span> 个)</span>
            <span style="font-size:0.75rem; font-weight:normal; color:var(--text-muted); margin-left:8px;">参考 singbox-sub-converter 逻辑动态从 sub.19910417.xyz 获取</span>
          </div>
          <div style="display:flex; gap:8px;">
            <button class="btn btn-sm" style="background:#10b981;" id="btn-refresh-ip" onclick="refreshPreferredIPs()">🔄 刷新优选 IP</button>
            <button class="btn btn-secondary btn-sm" onclick="copyAllNodes()">复制全部链接</button>
          </div>
        </div>
        <div id="nodes-container"></div>
      </div>

    </div>

    <!-- TAB 2: 配置管理 -->
    <div id="tab-config" class="tab-pane" style="display:none;">
      <div class="card">
        <div class="card-title">
          <span>🛠️ 核心协议与路径配置</span>
          <button class="btn btn-success btn-sm" onclick="saveAllConfig()">💾 保存配置至 KV</button>
        </div>

        <div class="form-group">
          <label class="form-label">VLESS 用户 UUID</label>
          <div class="input-with-action">
            <input type="text" id="cfg-uuid" class="form-control">
            <button class="btn btn-secondary" onclick="generateRandomUUID()">🎲 生成随机</button>
          </div>
          <p class="help-text">客户端连接鉴权使用的 UUID。</p>
        </div>

        <div class="form-group">
          <label class="form-label">VLESS WebSocket 代理路径 (Proxy Path)</label>
          <div class="input-with-action">
            <input type="text" id="cfg-proxy-path" class="form-control">
            <button class="btn btn-secondary" onclick="generateRandomPath()">🎲 生成混淆路径</button>
          </div>
          <p class="help-text">用于匹配 VLESS WS 流量的私有路径，修改后需在客户端同步更新。</p>
        </div>

        <div class="form-group">
          <label class="form-label">住宅 IP / 上游代理 (Upstream Residential Proxy)</label>
          <div class="input-with-action" style="align-items: flex-start;">
            <textarea id="cfg-upstream" rows="2" class="form-control" style="resize: vertical; font-family: monospace; font-size: 0.85rem;" placeholder="例如: socks5://user:pass@host:1080 或 openvpn://vpn:vpn@ip:443 或粘贴 .ovpn 文本"></textarea>
            <button class="btn btn-secondary" style="height: 42px; flex-shrink: 0;" onclick="testUpstreamLive()">⚡ 测试连通性</button>
          </div>
          <div id="upstream-test-res" class="test-result-box"></div>
          <p class="help-text">
            支持 <b>SOCKS5</b>、<b>HTTP</b> 与 <b>OpenVPN</b> 代理格式：<br>
            • <code>socks5://username:password@ip:port</code><br>
            • <code>openvpn://username:password@ip:port</code> 或 <code>ovpn://ip:port</code>（默认凭据 vpn:vpn）<br>
            • <code>http://username:password@ip:port</code><br>
            • OpenVPN <code>.ovpn</code> 配置文件完整文本或 Base64 编码字符串（自动解析 remote 节点）<br>
            • <code>ip:port:username:password</code> 或 <code>ip:port</code><br>
            • 留空则代表直接由 Cloudflare 边缘节点直连目标。
          </p>
        </div>

        <!-- 代理修改推送专属 REST API Token -->
        <div class="form-group" style="padding: 14px; background: #090d16; border-radius: var(--radius); border: 1px solid rgba(59, 130, 246, 0.3);">
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom: 6px;">
            <label class="form-label" style="margin-bottom:0; font-weight:600; color:#38bdf8;">🔑 代理修改推送专属 REST API Token (独立鉴权)</label>
            <span style="font-size:0.75rem; color:var(--text-muted);">供外部程序/守护进程自动推送修改</span>
          </div>
          <div class="input-with-action">
            <input type="text" id="cfg-api-token" class="form-control" placeholder="输入或生成 API 推送 Token..." oninput="updateRestSnippets(this.value)">
            <button class="btn btn-secondary" onclick="generateRandomAPIToken()">🎲 生成随机 Token</button>
            <button class="btn btn-secondary btn-sm" onclick="copyInputText('cfg-api-token')">复制</button>
          </div>
          <p class="help-text">外部程序可通过 <code>POST /api/upstream</code> 携带该 Token 自动推送更新代理，无需管理员密码。</p>
        </div>

        <div class="form-group">
          <label class="form-label">Clash 规则配置文件 URL (Config URL)</label>
          <input type="text" id="cfg-config-url" class="form-control" placeholder="https://raw.githubusercontent.com/JayYang1991/ACL4SSR/refs/heads/main/Clash/config/ACL4SSR_Online_Bespoke.ini">
          <p class="help-text">用于 subapi 转换生成 Clash Meta 配置时的规则模板。</p>
        </div>

        <div class="form-group">
          <label class="form-label">优选 IP 动态拉取源 URL (PREFERRED_SUB_URL)</label>
          <input type="text" id="cfg-preferred-sub-url" class="form-control" placeholder="https://sub.19910417.xyz">
          <p class="help-text">用于动态获取 Cloudflare 优选 IP 节点的订阅源地址（内置默认: <code>https://sub.19910417.xyz</code>）。</p>
        </div>

        <div class="form-group">
          <label class="form-label">Subapi 在线转换接口 URL (SUBAPI_URL)</label>
          <input type="text" id="cfg-subapi-url" class="form-control" placeholder="https://subapi.19910417.xyz">
          <p class="help-text">用于在线转换生成 Clash 与 Sing-box 客户端配置文件的 subapi 接口（内置默认: <code>https://subapi.19910417.xyz</code>）。</p>
        </div>

        <div class="form-group">
          <label class="form-label">优选 IP / 域名备用列表 (动态接口异常时的本地兜底，每行一个)</label>
          <textarea id="cfg-clean-ips" class="form-control" rows="3"></textarea>
          <p class="help-text">当 sub.19910417.xyz 不可用时自动兜底使用的 IP/域名。</p>
        </div>

        <div class="form-group">
          <label class="form-label">节点名称前缀</label>
          <input type="text" id="cfg-node-name" class="form-control">
        </div>

        <div class="form-group">
          <label class="form-label">修改管理密码 (留空则不修改)</label>
          <input type="password" id="cfg-new-pass" class="form-control" placeholder="输入新管理密码...">
        </div>

        <div style="margin-top: 20px;">
          <button class="btn btn-success" style="width: 100%; justify-content: center;" onclick="saveAllConfig()">💾 确认并立即保存所有配置</button>
        </div>
      </div>

      <!-- REST API 外部调用指南卡片 -->
      <div class="card">
        <div class="card-title">
          <span>🚀 代理自动推送 REST 接口使用指南</span>
        </div>
        <div style="font-size: 0.85rem; color: var(--text-muted); margin-bottom: 12px;">
          接口地址：<code id="rest-endpoint-url" style="color:#38bdf8; font-weight:600;">https://<domain>/api/upstream</code>
        </div>
        
        <div class="form-group">
          <label class="form-label">1. cURL 快速推送 OpenVPN / SOCKS5 代理示例 (纯文本/单行)</label>
          <div class="code-block" id="curl-text-example"></div>
        </div>

        <div class="form-group">
          <label class="form-label">2. cURL JSON 推送示例 (支持同时连通性测速)</label>
          <div class="code-block" id="curl-json-example"></div>
        </div>

        <div class="form-group">
          <label class="form-label">3. Python 自动化保活脚本推送代码片段</label>
          <div class="code-block" id="python-push-example"></div>
        </div>
      </div>
    </div>

    <!-- TAB 3: 客户端配置片段 -->
    <div id="tab-client" class="tab-pane" style="display:none;">
      <div class="card">
        <div class="card-title">
          <span>Sing-box 出站配置 (Outbounds JSON 片段)</span>
          <button class="btn btn-secondary btn-sm" onclick="copyText(appData.singbox)">复制代码</button>
        </div>
        <div class="code-block" id="singbox-code"></div>
      </div>

      <div class="card">
        <div class="card-title">
          <span>Clash Meta / Mihomo 配置 (Proxies YAML 片段)</span>
          <button class="btn btn-secondary btn-sm" onclick="copyText(appData.clash)">复制代码</button>
        </div>
        <div class="code-block" id="clash-code"></div>
      </div>
    </div>

  </div>

  <div id="toast"></div>

  <script>
    let appData = {};
    let currentQRString = '';
    let subconfigsLoaded = false;

    async function doLogin() {
      const passInput = document.getElementById('login-pass');
      const errorDiv = document.getElementById('login-error-msg');
      const loginBtn = document.getElementById('btn-do-login');
      const pass = passInput ? passInput.value.trim() : '';

      if (errorDiv) {
        errorDiv.style.display = 'none';
        errorDiv.innerText = '';
      }

      if (!pass) {
        if (errorDiv) {
          errorDiv.innerText = '❌ 请输入管理密码';
          errorDiv.style.display = 'block';
        }
        return showToast('请输入密码', 'error');
      }

      if (loginBtn) {
        loginBtn.disabled = true;
        loginBtn.innerText = '⏳ 正在验证并登录...';
      }

      try {
        const res = await fetch('${adminPath}/api/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ password: pass })
        });
        const data = await res.json();
        if (data.success && data.token) {
          localStorage.setItem('vless_token', data.token);
          document.getElementById('login-overlay').style.display = 'none';
          document.getElementById('app-container').style.display = 'block';
          showToast('✅ 登录成功！', 'success');
          loadDashboard();
        } else {
          const errMsg = data.message || '密码错误，请重试';
          if (errorDiv) {
            errorDiv.innerText = '❌ ' + errMsg;
            errorDiv.style.display = 'block';
          }
          showToast(errMsg, 'error');
        }
      } catch (err) {
        const errMsg = '登录请求异常: ' + (err.message || err);
        if (errorDiv) {
          errorDiv.innerText = '❌ ' + errMsg;
          errorDiv.style.display = 'block';
        }
        showToast(errMsg, 'error');
      } finally {
        if (loginBtn) {
          loginBtn.disabled = false;
          loginBtn.innerText = '登 录';
        }
      }
    }

    function doLogout() {
      localStorage.removeItem('vless_token');
      location.reload();
    }

    async function loadDashboard() {
      const token = localStorage.getItem('vless_token');
      const errorDiv = document.getElementById('login-error-msg');

      if (!token) {
        document.getElementById('login-overlay').style.display = 'flex';
        return;
      }

      try {
        const res = await fetch('${adminPath}/api/config', {
          headers: { 'Authorization': 'Bearer ' + token }
        });
        if (res.status === 401) {
          localStorage.removeItem('vless_token');
          document.getElementById('login-overlay').style.display = 'flex';
          if (errorDiv) {
            errorDiv.innerText = '🔐 登录会话已失效，请重新输入密码登录';
            errorDiv.style.display = 'block';
          }
          return;
        }

        if (!res.ok) {
          const errText = await res.text();
          throw new Error('服务端返回 HTTP ' + res.status + ': ' + errText);
        }

        appData = await res.json();
        document.getElementById('login-overlay').style.display = 'none';
        document.getElementById('app-container').style.display = 'block';

        renderUI();
        if (!subconfigsLoaded) {
          loadSubconfigs();
        }
      } catch (err) {
        showToast('加载配置失败: ' + err.message, 'error');
      }
    }

    async function loadSubconfigs() {
      try {
        const res = await fetch('${adminPath}/api/subconfigs');
        if (res.ok) {
          const groups = await res.json();
          renderSubconfigOptions(groups);
          subconfigsLoaded = true;
        }
      } catch (err) {
        console.error('Failed to load subconfigs:', err);
      }
    }

    function renderSubconfigOptions(groups) {
      const select = document.getElementById('cfg-subconfig-select');
      if (!select || !Array.isArray(groups) || groups.length === 0) return;
      select.innerHTML = '';

      const currentCfg = (appData.config && appData.config.configUrl) || '';
      let matched = false;

      groups.forEach(g => {
        const optgroup = document.createElement('optgroup');
        optgroup.label = g.label || '规则分组';
        if (Array.isArray(g.options)) {
          g.options.forEach(opt => {
            const option = document.createElement('option');
            option.value = opt.value;
            option.textContent = opt.label;
            if (opt.value === currentCfg) {
              option.selected = true;
              matched = true;
            }
            optgroup.appendChild(option);
          });
        }
        select.appendChild(optgroup);
      });

      if (!matched && currentCfg) {
        const customOpt = document.createElement('option');
        customOpt.value = currentCfg;
        customOpt.textContent = '自定义规则: ' + currentCfg;
        customOpt.selected = true;
        select.insertBefore(customOpt, select.firstChild);
      }
    }

    async function handleSubconfigChange() {
      const select = document.getElementById('cfg-subconfig-select');
      const val = select.value;
      document.getElementById('cfg-config-url').value = val;
      const tip = document.getElementById('cfg-status-tip');
      tip.innerText = '正在保存至服务端...';
      tip.style.color = '#f59e0b';

      const token = localStorage.getItem('vless_token');
      try {
        const res = await fetch('${adminPath}/api/config', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + token
          },
          body: JSON.stringify({ configUrl: val })
        });
        const data = await res.json();
        if (data.success) {
          tip.innerText = '✅ 已保存至服务端';
          tip.style.color = 'var(--success)';
          showToast('✅ 规则配置已切换并保存！', 'success');
        } else {
          tip.innerText = '❌ 保存失败';
          tip.style.color = 'var(--danger)';
        }
      } catch (e) {
        tip.innerText = '❌ 保存异常';
        tip.style.color = 'var(--danger)';
      }
    }

    async function refreshPreferredIPs() {
      const btn = document.getElementById('btn-refresh-ip');
      if (btn) {
        btn.disabled = true;
        btn.innerText = '🔄 正在刷新优选 IP...';
      }
      const token = localStorage.getItem('vless_token');
      try {
        const res = await fetch('${adminPath}/api/refresh-ip', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + token
          }
        });
        const data = await res.json();
        if (data.success) {
          showToast('✅ ' + data.message + ' (共获取 ' + data.count + ' 个节点)', 'success');
          loadDashboard();
        } else {
          showToast('❌ 刷新失败: ' + (data.error || data.message), 'error');
        }
      } catch (err) {
        showToast('刷新异常: ' + err.message, 'error');
      } finally {
        if (btn) {
          btn.disabled = false;
          btn.innerText = '🔄 刷新优选 IP';
        }
      }
    }

    function renderUI() {
      document.getElementById('lbl-domain').innerText = appData.workerDomain;
      document.getElementById('kv-status').innerText = appData.kvEnabled ? '● KV 持久化生效' : '⚠️ KV 未绑定 (仅环境变量)';
      if (!appData.kvEnabled) {
        document.getElementById('kv-status').style.color = '#f59e0b';
      }

      // 订阅链接填充
      if (appData.subscriptions) {
        if (document.getElementById('sub-adaptive-url')) {
          document.getElementById('sub-adaptive-url').value = appData.subscriptions.adaptive || '';
        }
        document.getElementById('sub-clash-url').value = appData.subscriptions.clash || '';
        document.getElementById('sub-singbox-url').value = appData.subscriptions.singbox || '';
        document.getElementById('sub-vless-url').value = appData.subscriptions.vless || '';
      }

      // 表单填充
      document.getElementById('cfg-uuid').value = appData.config.uuid || '';
      document.getElementById('cfg-proxy-path').value = appData.config.proxyPath || '';
      document.getElementById('cfg-upstream').value = appData.config.upstreamProxy || '';
      if (document.getElementById('cfg-api-token')) {
        document.getElementById('cfg-api-token').value = appData.config.apiToken || '';
      }
      document.getElementById('cfg-clean-ips').value = appData.config.cleanIPs || '';
      document.getElementById('cfg-node-name').value = appData.config.nodeName || '';
      if (document.getElementById('cfg-config-url')) {
        document.getElementById('cfg-config-url').value = appData.config.configUrl || '';
      }
      if (document.getElementById('cfg-preferred-sub-url')) {
        document.getElementById('cfg-preferred-sub-url').value = appData.config.preferredSubUrl || '';
      }
      if (document.getElementById('cfg-subapi-url')) {
        document.getElementById('cfg-subapi-url').value = appData.config.subapiUrl || '';
      }

      // 渲染 REST API 指南
      updateRestSnippets(appData.config.apiToken || '');

      // 渲染节点列表
      const nodesDiv = document.getElementById('nodes-container');
      nodesDiv.innerHTML = '';
      const nodes = appData.nodes || [];
      document.getElementById('lbl-node-count').innerText = nodes.length;

      nodes.forEach((node) => {
        const item = document.createElement('div');
        item.className = 'node-item';
        item.innerHTML = \`
          <div class="node-info">
            <div class="node-name">\${escapeHtml(node.name)}</div>
            <div class="node-url">\${escapeHtml(node.url)}</div>
          </div>
          <div style="display:flex; gap:6px; flex-shrink: 0;">
            <button class="btn btn-secondary btn-sm" onclick="copyText('\${escapeHtml(node.url)}')">复制</button>
            <button class="btn btn-sm" onclick="showQRModal('\${escapeHtml(node.name)}', '\${escapeHtml(node.url)}')">📱 二维码</button>
          </div>
        \`;
        nodesDiv.appendChild(item);
      });

      document.getElementById('singbox-code').innerText = appData.singbox;
      document.getElementById('clash-code').innerText = appData.clash;
    }

    function updateRestSnippets(token) {
      const restEndpoint = (appData.restApi && appData.restApi.endpoint) || (window.location.origin + '/api/upstream');
      const curToken = (token || (appData.config && appData.config.apiToken) || 'YOUR_API_TOKEN').trim();
      if (document.getElementById('rest-endpoint-url')) {
        document.getElementById('rest-endpoint-url').innerText = restEndpoint;
      }
      if (document.getElementById('curl-text-example')) {
        document.getElementById('curl-text-example').innerText = [
          '# 推送 OpenVPN 格式或 SOCKS5 代理：',
          'curl -X POST ' + restEndpoint + ' \\\\',
          '  -H "Authorization: Bearer ' + curToken + '" \\\\',
          '  -d "openvpn://vpn:vpn@219.100.37.13:443"'
        ].join('\\n');
      }
      if (document.getElementById('curl-json-example')) {
        const samplePayload = JSON.stringify({ upstreamProxy: "openvpn://vpn:vpn@219.100.37.13:443", test: true });
        document.getElementById('curl-json-example').innerText = [
          '# JSON 格式推送并执行在线握手测速：',
          'curl -X POST ' + restEndpoint + ' \\\\',
          '  -H "Authorization: Bearer ' + curToken + '" \\\\',
          '  -H "Content-Type: application/json" \\\\',
          "  -d '" + samplePayload + "'"
        ].join('\\n');
      }
      if (document.getElementById('python-push-example')) {
        document.getElementById('python-push-example').innerText = [
          'import requests',
          '',
          'API_URL = "' + restEndpoint + '"',
          'API_TOKEN = "' + curToken + '"',
          '',
          '# 推送最优住宅代理 (支持 SOCKS5 / HTTP / OpenVPN 格式)',
          'resp = requests.post(',
          '    API_URL,',
          '    headers={"Authorization": f"Bearer {API_TOKEN}", "Content-Type": "application/json"},',
          '    json={"upstreamProxy": "openvpn://vpn:vpn@219.100.37.13:443", "test": True},',
          '    timeout=15',
          ')',
          'print("Response:", resp.json())'
        ].join('\\n');
      }
    }

    async function generateRandomAPIToken() {
      const bytes = new Uint8Array(20);
      crypto.getRandomValues(bytes);
      const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
      const newToken = 'cf-push-' + hex;
      document.getElementById('cfg-api-token').value = newToken;
      updateRestSnippets(newToken);
      showToast('🎲 已生成新 Token，点击下方保存即可持久化生效', 'success');
    }

    async function saveAllConfig() {
      const token = localStorage.getItem('vless_token');
      const payload = {
        uuid: document.getElementById('cfg-uuid').value.trim(),
        proxyPath: document.getElementById('cfg-proxy-path').value.trim(),
        upstreamProxy: document.getElementById('cfg-upstream').value.trim(),
        apiToken: document.getElementById('cfg-api-token') ? document.getElementById('cfg-api-token').value.trim() : '',
        cleanIPs: document.getElementById('cfg-clean-ips').value.trim(),
        nodeName: document.getElementById('cfg-node-name').value.trim(),
        configUrl: document.getElementById('cfg-config-url') ? document.getElementById('cfg-config-url').value.trim() : '',
        preferredSubUrl: document.getElementById('cfg-preferred-sub-url') ? document.getElementById('cfg-preferred-sub-url').value.trim() : '',
        subapiUrl: document.getElementById('cfg-subapi-url') ? document.getElementById('cfg-subapi-url').value.trim() : '',
      };

      const newPass = document.getElementById('cfg-new-pass').value.trim();
      if (newPass) {
        payload.adminPassword = newPass;
      }

      try {
        const res = await fetch('${adminPath}/api/config', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + token
          },
          body: JSON.stringify(payload)
        });

        const data = await res.json();
        if (data.success) {
          showToast('✅ 配置已成功保存至 KV！', 'success');
          loadDashboard();
        } else {
          showToast('❌ 保存失败: ' + (data.error || data.message), 'error');
        }
      } catch (err) {
        showToast('保存异常: ' + err.message, 'error');
      }
    }

    async function testUpstreamLive() {
      const token = localStorage.getItem('vless_token');
      const upstream = document.getElementById('cfg-upstream').value.trim();
      const resBox = document.getElementById('upstream-test-res');
      const btn = document.querySelector("button[onclick='testUpstreamLive()']");

      if (!upstream) {
        resBox.className = 'test-result-box';
        resBox.style.display = 'block';
        resBox.innerText = 'ℹ️ 未填写住宅代理地址（留空表示直连模式，无需测试）。';
        return;
      }

      resBox.className = 'test-result-box';
      resBox.style.display = 'block';
      resBox.innerText = '⏳ 正在向住宅代理发起握手与连通性测试 (限时 60 秒)，请稍候...';
      if (btn) {
        btn.disabled = true;
        btn.innerText = '⏳ 测试中...';
      }

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 65000);

      try {
        const res = await fetch('${adminPath}/api/test-upstream', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + token
          },
          body: JSON.stringify({ upstreamProxy: upstream }),
          signal: controller.signal
        });
        clearTimeout(timeoutId);
        const data = await res.json();
        if (data.success) {
          resBox.className = 'test-result-box success';
          resBox.innerText = '✅ ' + data.message;
        } else {
          resBox.className = 'test-result-box error';
          resBox.innerText = '❌ ' + (data.message || data.error || '测试失败');
        }
      } catch (e) {
        clearTimeout(timeoutId);
        resBox.className = 'test-result-box error';
        if (e.name === 'AbortError') {
          resBox.innerText = '❌ 连接超时：住宅代理服务器未在规定时间内响应，请检查 IP/域名/端口 是否开放或防火墙策略。';
        } else {
          resBox.innerText = '❌ 请求异常: ' + e.message;
        }
      } finally {
        if (btn) {
          btn.disabled = false;
          btn.innerText = '⚡ 测试连通性';
        }
      }
    }

    function switchTab(tabId) {
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      document.querySelectorAll('.tab-pane').forEach(p => p.style.display = 'none');
      event.target.classList.add('active');
      document.getElementById(tabId).style.display = 'block';
    }

    function generateRandomUUID() {
      const uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
      });
      document.getElementById('cfg-uuid').value = uuid;
      showToast('已生成新 UUID，记得点击保存', 'success');
    }

    function generateRandomPath() {
      const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
      let path = '/';
      for (let i = 0; i < 12; i++) {
        path += chars.charAt(Math.floor(Math.random() * chars.length));
      }
      document.getElementById('cfg-proxy-path').value = path;
      showToast('已生成随机路径，记得点击保存', 'success');
    }

    function copyInputText(inputId) {
      const input = document.getElementById(inputId);
      copyText(input.value);
    }

    function copyText(text) {
      navigator.clipboard.writeText(text).then(() => {
        showToast('已成功复制到剪贴板！', 'success');
      }).catch(() => {
        showToast('复制失败，请手动选择复制', 'error');
      });
    }

    function copyAllNodes() {
      if (!appData.nodes || !appData.nodes.length) return;
      const all = appData.nodes.map(n => n.url).join('\\n');
      copyText(all);
    }

    function copyCurrentQRText() {
      if (currentQRString) copyText(currentQRString);
    }

    function escapeHtml(str) {
      if (!str) return '';
      return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;');
    }

    function showToast(msg, type = 'info') {
      const toast = document.getElementById('toast');
      toast.innerText = msg;
      toast.className = 'show ' + type;
      setTimeout(() => { toast.className = ''; }, 3000);
    }

    // ==========================================
    // 纯原生 JavaScript 二维码生成引擎 (QR Engine)
    // ==========================================
    function showQRModal(title, text) {
      currentQRString = text;
      document.getElementById('qr-modal-title').innerText = title;
      document.getElementById('qr-modal-text').innerText = text;
      const container = document.getElementById('qr-container');
      container.innerHTML = '';

      try {
        const svg = generateQRCodeSVG(text, 220);
        container.innerHTML = svg;
      } catch (err) {
        container.innerHTML = '<div style="color:red; font-size:12px;">生成二维码失败: ' + err.message + '</div>';
      }

      document.getElementById('qr-modal').style.display = 'flex';
    }

    function closeQRModal() {
      document.getElementById('qr-modal').style.display = 'none';
    }

    /**
     * 内置极简纯原生 QR Code 矩阵生成算法
     */
    function generateQRCodeSVG(text, size = 220) {
      const qr = qrcode(0, 'M');
      qr.addData(text);
      qr.make();
      return qr.createSvgTag(size / qr.getModuleCount(), 0);
    }

    // 经典轻量级 QR Code 核心引擎
    (function(){
      function QR8bitByte(data){this.mode=4;this.data=data;}
      QR8bitByte.prototype={getLength:function(){return this.data.length;},write:function(buffer){for(var i=0;i<this.data.length;i++){buffer.put(this.data.charCodeAt(i),8);}}};
      function QRCodeModel(typeNumber,errorCorrectLevel){this.typeNumber=typeNumber;this.errorCorrectLevel=errorCorrectLevel;this.modules=null;this.moduleCount=0;this.dataCache=null;this.dataList=[];}
      QRCodeModel.prototype={
        addData:function(data){var newData=new QR8bitByte(data);this.dataList.push(newData);this.dataCache=null;},
        isDark:function(row,col){return this.modules[row][col];},
        getModuleCount:function(){return this.moduleCount;},
        make:function(){
          if(this.typeNumber<1){
            var typeNumber=1;
            for(typeNumber=1;typeNumber<40;typeNumber++){
              var rsBlocks=QRRSBlock.getRSBlocks(typeNumber,this.errorCorrectLevel);
              var buffer=new QRBitBuffer();
              for(var i=0;i<this.dataList.length;i++){var d=this.dataList[i];buffer.put(d.mode,4);buffer.put(d.getLength(),QRUtil.getLengthInBits(d.mode,typeNumber));d.write(buffer);}
              var totalDataCount=0;
              for(var i=0;i<rsBlocks.length;i++){totalDataCount+=rsBlocks[i].dataCount;}
              if(buffer.getLengthInBits()<=totalDataCount*8)break;
            }
            this.typeNumber=typeNumber;
          }
          this.makeImpl(false,this.getBestMaskPattern());
        },
        makeImpl:function(test,maskPattern){
          this.moduleCount=this.typeNumber*4+17;
          this.modules=new Array(this.moduleCount);
          for(var row=0;row<this.moduleCount;row++){this.modules[row]=new Array(this.moduleCount);for(var col=0;col<this.moduleCount;col++){this.modules[row][col]=null;}}
          this.setupPositionProbePattern(0,0);
          this.setupPositionProbePattern(this.moduleCount-7,0);
          this.setupPositionProbePattern(0,this.moduleCount-7);
          this.setupPositionAdjustPattern();
          this.setupTimingPattern();
          this.setupTypeInfo(test,maskPattern);
          if(this.typeNumber>=7){this.setupTypeNumber(test);}
          if(this.dataCache==null){this.dataCache=QRCodeModel.createData(this.typeNumber,this.errorCorrectLevel,this.dataList);}
          this.mapData(this.dataCache,maskPattern);
        },
        setupPositionProbePattern:function(row,col){
          for(var r=-1;r<=7;r++){
            if(row+r<=-1||this.moduleCount<=row+r)continue;
            for(var c=-1;c<=7;c++){
              if(col+c<=-1||this.moduleCount<=col+c)continue;
              if((0<=r&&r<=6&&(c==0||c==6))||(0<=c&&c<=6&&(r==0||r==6))||(2<=r&&r<=4&&2<=c&&c<=4)){this.modules[row+r][col+c]=true;}else{this.modules[row+r][col+c]=false;}
            }
          }
        },
        getBestMaskPattern:function(){var minLostPoint=0;var pattern=0;for(var i=0;i<8;i++){this.makeImpl(true,i);var lostPoint=QRUtil.getLostPoint(this);if(i==0||minLostPoint>lostPoint){minLostPoint=lostPoint;pattern=i;}}return pattern;},
        createSvgTag:function(cellSize,margin){
          cellSize=cellSize||4;margin=margin||0;
          var size=this.getModuleCount()*cellSize+margin*2;
          var svg=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 '+size+' '+size+'" width="'+size+'" height="'+size+'">'];
          svg.push('<rect width="100%" height="100%" fill="#ffffff"/>');
          for(var r=0;r<this.getModuleCount();r++){
            for(var c=0;c<this.getModuleCount();c++){
              if(this.isDark(r,c)){
                var x=c*cellSize+margin;var y=r*cellSize+margin;
                svg.push('<rect x="'+x+'" y="'+y+'" width="'+cellSize+'" height="'+cellSize+'" fill="#000000"/>');
              }
            }
          }
          svg.push('</svg>');
          return svg.join('');
        },
        setupTimingPattern:function(){
          for(var r=8;r<this.moduleCount-8;r++){if(this.modules[r][6]!=null)continue;this.modules[r][6]=(r%2==0);}
          for(var c=8;c<this.moduleCount-8;c++){if(this.modules[6][c]!=null)continue;this.modules[6][c]=(c%2==0);}
        },
        setupPositionAdjustPattern:function(){
          var pos=QRUtil.getPatternPosition(this.typeNumber);
          for(var i=0;i<pos.length;i++){
            for(var j=0;j<pos.length;j++){
              var row=pos[i];var col=pos[j];
              if(this.modules[row][col]!=null)continue;
              for(var r=-2;r<=2;r++){
                for(var c=-2;c<=2;c++){
                  if(r==-2||r==2||c==-2||c==2||(r==0&&c==0)){this.modules[row+r][col+c]=true;}else{this.modules[row+r][col+c]=false;}
                }
              }
            }
          }
        },
        setupTypeNumber:function(test){
          var bits=QRUtil.getBCHTypeNumber(this.typeNumber);
          for(var i=0;i<18;i++){var mod=(!test&&((bits>>i)&1)==1);this.modules[Math.floor(i/3)][i%3+this.moduleCount-8-3]=mod;}
          for(var i=0;i<18;i++){var mod=(!test&&((bits>>i)&1)==1);this.modules[i%3+this.moduleCount-8-3][Math.floor(i/3)]=mod;}
        },
        setupTypeInfo:function(test,maskPattern){
          var data=(1<<3)|maskPattern;
          var bits=QRUtil.getBCHTypeInfo(data);
          for(var i=0;i<15;i++){
            var mod=(!test&&((bits>>i)&1)==1);
            if(i<6){this.modules[i][8]=mod;}else if(i<8){this.modules[i+1][8]=mod;}else{this.modules[this.moduleCount-15+i][8]=mod;}
          }
          for(var i=0;i<15;i++){
            var mod=(!test&&((bits>>i)&1)==1);
            if(i<8){this.modules[8][this.moduleCount-i-1]=mod;}else if(i<9){this.modules[8][15-i-1+1]=mod;}else{this.modules[8][15-i-1]=mod;}
          }
          this.modules[this.moduleCount-8][8]=(!test);
        },
        mapData:function(data,maskPattern){
          var inc=-1;var row=this.moduleCount-1;var bitIndex=7;var byteIndex=0;
          for(var col=this.moduleCount-1;col>0;col-=2){
            if(col==6)col--;
            while(true){
              for(var c=0;c<2;c++){
                if(this.modules[row][col-c]==null){
                  var dark=false;
                  if(byteIndex<data.length){dark=(((data[byteIndex]>>>bitIndex)&1)==1);}
                  var mask=QRUtil.getMask(maskPattern,row,col-c);
                  if(mask){dark=!dark;}
                  this.modules[row][col-c]=dark;
                  bitIndex--;
                  if(bitIndex==-1){byteIndex++;bitIndex=7;}
                }
              }
              row+=inc;
              if(row<0||this.moduleCount<=row){row-=inc;inc=-inc;break;}
            }
          }
        }
      };
      QRCodeModel.createData=function(typeNumber,errorCorrectLevel,dataList){
        var rsBlocks=QRRSBlock.getRSBlocks(typeNumber,errorCorrectLevel);
        var buffer=new QRBitBuffer();
        for(var i=0;i<dataList.length;i++){var d=dataList[i];buffer.put(d.mode,4);buffer.put(d.getLength(),QRUtil.getLengthInBits(d.mode,typeNumber));d.write(buffer);}
        var totalDataCount=0;
        for(var i=0;i<rsBlocks.length;i++){totalDataCount+=rsBlocks[i].dataCount;}
        if(buffer.getLengthInBits()>totalDataCount*8){throw new Error("Data overflow for QR Code");}
        if(buffer.getLengthInBits()+4<=totalDataCount*8){buffer.put(0,4);}
        while(buffer.getLengthInBits()%8!=0){buffer.putBit(false);}
        while(true){
          if(buffer.getLengthInBits()>=totalDataCount*8)break;
          buffer.put(236,8);
          if(buffer.getLengthInBits()>=totalDataCount*8)break;
          buffer.put(17,8);
        }
        return QRCodeModel.createBytes(buffer,rsBlocks);
      };
      QRCodeModel.createBytes=function(buffer,rsBlocks){
        var offset=0;var maxDcCount=0;var maxEcCount=0;
        var dcdata=new Array(rsBlocks.length);var ecdata=new Array(rsBlocks.length);
        for(var r=0;r<rsBlocks.length;r++){
          var dcCount=rsBlocks[r].dataCount;var ecCount=rsBlocks[r].totalCount-dcCount;
          maxDcCount=Math.max(maxDcCount,dcCount);maxEcCount=Math.max(maxEcCount,ecCount);
          dcdata[r]=new Array(dcCount);
          for(var i=0;i<dcdata[r].length;i++){dcdata[r][i]=0xff&buffer.buffer[i+offset];}
          offset+=dcCount;
          var rsPoly=QRUtil.getErrorCorrectPolynomial(ecCount);
          var rawPoly=new QRPolynomial(dcdata[r],rsPoly.getLength()-1);
          var modPoly=rawPoly.mod(rsPoly);
          ecdata[r]=new Array(rsPoly.getLength()-1);
          for(var i=0;i<ecdata[r].length;i++){var modIndex=i+modPoly.getLength()-ecdata[r].length;ecdata[r][i]=(modIndex>=0)?modPoly.get(modIndex):0;}
        }
        var totalCodeCount=0;
        for(var i=0;i<rsBlocks.length;i++){totalCodeCount+=rsBlocks[i].totalCount;}
        var data=new Array(totalCodeCount);var index=0;
        for(var i=0;i<maxDcCount;i++){for(var r=0;r<rsBlocks.length;r++){if(i<dcdata[r].length){data[index++]=dcdata[r][i];}}}
        for(var i=0;i<maxEcCount;i++){for(var r=0;r<rsBlocks.length;r++){if(i<ecdata[r].length){data[index++]=ecdata[r][i];}}}
        return data;
      };
      var QRUtil={
        PATTERN_POSITION_TABLE:[[],[6,18],[6,22],[6,26],[6,30],[6,34],[6,22,38],[6,24,42],[6,26,46],[6,28,50],[6,30,54],[6,32,58],[6,34,62],[6,26,46,66],[6,26,48,70],[6,26,50,74],[6,30,54,78],[6,30,56,82],[6,30,58,86],[6,34,62,90],[6,28,50,72,94],[6,26,50,74,98],[6,30,54,78,102],[6,28,54,80,106],[6,32,58,84,110],[6,30,58,86,114],[6,34,62,90,118],[6,26,50,74,98,122],[6,30,54,78,102,126],[6,26,52,78,104,130],[6,30,56,82,108,134],[6,34,60,86,112,138],[6,30,58,86,114,142],[6,34,62,90,118,146],[6,30,54,78,102,126,150],[6,24,50,76,102,128,154],[6,28,54,80,106,132,158],[6,32,58,84,110,136,162],[6,26,54,82,110,138,166],[6,30,58,86,114,142,170]],
        getPatternPosition:function(typeNumber){return this.PATTERN_POSITION_TABLE[typeNumber-1];},
        getMask:function(maskPattern,i,j){
          switch(maskPattern){
            case 0:return(i+j)%2==0;case 1:return i%2==0;case 2:return j%3==0;case 3:return(i+j)%3==0;
            case 4:return(Math.floor(i/2)+Math.floor(j/3))%2==0;case 5:return(i*j)%2+(i*j)%3==0;
            case 6:return((i*j)%2+(i*j)%3)%2==0;case 7:return((i*j)%3+(i+j)%2)%2==0;
            default:throw new Error("bad maskPattern:"+maskPattern);
          }
        },
        getErrorCorrectPolynomial:function(errorCorrectLength){
          var a=new QRPolynomial([1],0);
          for(var i=0;i<errorCorrectLength;i++){a=a.multiply(new QRPolynomial([1,QRMath.gexp(i)],0));}
          return a;
        },
        getLengthInBits:function(mode,type){if(1<=type&&type<10){return 8;}else if(type<27){return 16;}else{return 16;}},
        getLostPoint:function(qrCode){
          var moduleCount=qrCode.getModuleCount();var lostPoint=0;
          for(var row=0;row<moduleCount;row++){
            for(var col=0;col<moduleCount;col++){
              var sameCount=0;var dark=qrCode.isDark(row,col);
              for(var r=-1;r<=1;r++){if(row+r<0||moduleCount<=row+r)continue;for(var c=-1;c<=1;c++){if(col+c<0||moduleCount<=col+c)continue;if(r==0&&c==0)continue;if(dark==qrCode.isDark(row+r,col+c)){sameCount++;}}}
              if(sameCount>5){lostPoint+=(3+sameCount-5);}
            }
          }
          return lostPoint;
        },
        getBCHTypeInfo:function(data){var d=data<<10;while(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(1335)>=0){d^=(1335<<(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(1335)));}return((data<<10)|d)^21522;},
        getBCHTypeNumber:function(data){var d=data<<12;while(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(7973)>=0){d^=(7973<<(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(7973)));}return(data<<12)|d;},
        getBCHDigit:function(data){var digit=0;while(data!=0){digit++;data>>>=1;}return digit;}
      };
      var QRMath={
        EXP_TABLE:new Array(256),LOG_TABLE:new Array(256),
        glog:function(n){if(n<1)throw new Error("glog("+n+")");return QRMath.LOG_TABLE[n];},
        gexp:function(n){while(n<0){n+=255;}while(n>=255){n-=255;}return QRMath.EXP_TABLE[n];}
      };
      for(var i=0;i<8;i++){QRMath.EXP_TABLE[i]=1<<i;}
      for(var i=8;i<256;i++){QRMath.EXP_TABLE[i]=QRMath.EXP_TABLE[i-4]^QRMath.EXP_TABLE[i-5]^QRMath.EXP_TABLE[i-6]^QRMath.EXP_TABLE[i-8];}
      for(var i=0;i<255;i++){QRMath.LOG_TABLE[QRMath.EXP_TABLE[i]]=i;}
      function QRPolynomial(num,shift){
        var offset=0;while(offset<num.length&&num[offset]==0){offset++;}
        this.num=new Array(num.length-offset+shift);
        for(var i=0;i<num.length-offset;i++){this.num[i]=num[i+offset];}
      }
      QRPolynomial.prototype={
        get:function(index){return this.num[index];},
        getLength:function(){return this.num.length;},
        multiply:function(e){
          var num=new Array(this.getLength()+e.getLength()-1);
          for(var i=0;i<this.getLength();i++){for(var j=0;j<e.getLength();j++){num[i+j]^=QRMath.gexp(QRMath.glog(this.get(i))+QRMath.glog(e.get(j)));}}
          return new QRPolynomial(num,0);
        },
        mod:function(e){
          if(this.getLength()-e.getLength()<0)return this;
          var ratio=QRMath.glog(this.get(0))-QRMath.glog(e.get(0));
          var num=new Array(this.getLength());
          for(var i=0;i<this.getLength();i++){num[i]=this.get(i);}
          for(var i=0;i<e.getLength();i++){num[i]^=QRMath.gexp(QRMath.glog(e.get(i))+ratio);}
          return new QRPolynomial(num,0).mod(e);
        }
      };
      function QRRSBlock(totalCount,dataCount){this.totalCount=totalCount;this.dataCount=dataCount;}
      QRRSBlock.RS_BLOCK_TABLE=[
        [1,26,19],[1,44,34],[1,70,55],[1,100,80],[1,134,108],[2,86,68],[2,98,78],[2,121,97],[2,146,116],[2,86,68,2,87,69],
        [4,101,81],[2,116,92,2,117,93],[4,133,107],[3,145,115,1,146,116],[5,109,87,1,110,88],[5,122,98,1,123,99],[1,135,107,5,136,108],[5,150,120,1,151,121],[3,141,113,4,142,114],[3,135,107,5,136,108]
      ];
      QRRSBlock.getRSBlocks=function(typeNumber,errorCorrectLevel){
        var rsBlock=QRRSBlock.RS_BLOCK_TABLE[(typeNumber-1)*1];
        if(!rsBlock) rsBlock=[1,26,19];
        var list=[];
        for(var i=0;i<rsBlock.length;i+=3){
          var count=rsBlock[i];var totalCount=rsBlock[i+1];var dataCount=rsBlock[i+2];
          for(var j=0;j<count;j++){list.push(new QRRSBlock(totalCount,dataCount));}
        }
        return list;
      };
      function QRBitBuffer(){this.buffer=[];this.length=0;}
      QRBitBuffer.prototype={
        get:function(index){var bufIndex=Math.floor(index/8);return((this.buffer[bufIndex]>>>(7-index%8))&1)==1;},
        put:function(num,length){for(var i=0;i<length;i++){this.putBit(((num>>>(length-i-1))&1)==1);}},
        getLengthInBits:function(){return this.length;},
        putBit:function(bit){
          var bufIndex=Math.floor(this.length/8);
          if(this.buffer.length<=bufIndex){this.buffer.push(0);}
          if(bit){this.buffer[bufIndex]|=(0x80>>>(this.length%8));}
          this.length++;
        }
      };
      window.qrcode=function(typeNumber,errorCorrectLevel){return new QRCodeModel(typeNumber,errorCorrectLevel);};
    })();

    // 页面加载完成后自动获取配置
    window.addEventListener('DOMContentLoaded', () => {
      loadDashboard();
    });
  </script>
</body>
</html>`;
}
