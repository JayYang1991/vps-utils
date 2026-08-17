/**
 * edgetunnel 优选订阅与 Cloudflare WARP Endpoint 管理 Worker
 * 功能：
 * 1. /sub 接口：返回加密的节点列表（合并远程与本地 KV 优选 IP）。
 * 2. /warp 接口：返回本地 KV 保存的最新 Cloudflare WARP 优选 Endpoint 列表。
 * 3. /admin 接口：美观现代化的管理后台，支持编辑与切换 CDN 优选 IP、WARP 优选 Endpoint 及历史记录。
 * 4. /api/update 接口：支持 PUT 请求配合 Token 自动更新 CDN 优选 IP 或 WARP 优选 Endpoint。
 * 5. /api/history 接口：支持 GET 请求查询历史 IP 或 WARP Endpoint 记录。
 */

// 默认配置
const DEFAULT_SUB_SOURCE = 'https://sub.cmliussss.net';
const USER_AGENT = 'v2rayN/edgetunnel (https://github.com/cmliu/edgetunnel)';

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const path = url.pathname;

        // 1. 订阅接口 /sub
        if (path === '/sub') {
            return await handleSubRequest(request, env);
        }

        // 2. WARP Endpoint 接口 /warp
        if (path === '/warp') {
            return await handleWarpRequest(request, env);
        }

        // 3. 自动化 API 更新接口 /api/update (支持 PUT)
        if (path === '/api/update') {
            return await handleApiUpdate(request, env);
        }

        // 4. 历史记录 API 查询接口 /api/history (支持 GET)
        if (path === '/api/history') {
            return await handleApiHistory(request, env);
        }

        // 5. 管理后台 /admin
        if (path === '/admin' || path === '/login') {
            return await handleAdminRequest(request, env);
        }

        // 6. 默认返回
        return new Response('Not Found', { status: 404 });
    }
};

/**
 * 处理订阅请求 (/sub)
 */
async function handleSubRequest(request, env) {
    const { searchParams } = new URL(request.url);
    const host = searchParams.get('host');
    const uuid = searchParams.get('uuid');

    if (!host || !uuid) {
        return new Response('Missing host or uuid parameter', { status: 400 });
    }

    // 1. 获取远程优选 IP
    let remoteSource = env.SUB_SOURCE || DEFAULT_SUB_SOURCE;

    if (remoteSource.includes('sub.cmliussss.net')) {
        const baseUrl = remoteSource.endsWith('/sub') ? remoteSource : `${remoteSource.replace(/\/$/, '')}/sub`;
        remoteSource = `${baseUrl}?host=${host}&uuid=${uuid}`;
    } else if (remoteSource.includes('github.com') && !remoteSource.includes('raw.githubusercontent.com') && !remoteSource.includes('/raw/')) {
        remoteSource = remoteSource.replace('github.com', 'raw.githubusercontent.com').replace('/blob/', '/') + '/main/ADD.txt';
    }

    let remoteContent = '';
    try {
        const res = await fetch(remoteSource, {
            headers: { 'User-Agent': USER_AGENT }
        });
        if (res.ok) {
            let text = await res.text();
            if (isValidBase64(text)) {
                remoteContent = base64Decode(text);
            } else {
                remoteContent = text;
            }
        }
    } catch (e) {
        console.error('Fetch remote IPs failed:', e);
    }

    // 2. 获取 KV 本地优选 IP
    let localIps = '';
    if (env.KV) {
        localIps = await env.KV.get('ADD.txt') || '';
    }

    // 3. 合并并解析所有行
    const remoteLines = splitLines(remoteContent);
    const localLines = splitLines(localIps);

    const allIps = new Set();
    const otherNodes = [];

    // 解析远程内容
    for (const line of remoteLines) {
        if (line.startsWith('vless://') || line.startsWith('trojan://')) {
            const match = line.match(/@([^?#]+)/);
            if (match) {
                const addressPort = match[1];
                const address = addressPort.split(':')[0].trim().toLowerCase();
                if (address === 'example.com' || address === '0.0.0.0' || address === '127.0.0.1') {
                    continue;
                }
                const remarkMatch = line.match(/#(.+)$/);
                const remark = remarkMatch ? decodeURIComponent(remarkMatch[1]) : '';
                allIps.add(`${addressPort}#${remark}`);
            } else {
                otherNodes.push(line);
            }
        } else if (line.includes(':')) {
            const address = line.split(':')[0].trim().toLowerCase();
            if (address !== 'example.com' && address !== '0.0.0.0' && address !== '127.0.0.1') {
                allIps.add(line);
            }
        }
    }

    // 解析本地内容
    for (const line of localLines) {
        if (line.includes(':')) allIps.add(line);
    }

    // 4. 统一生成节点列表 (VLESS 格式)
    const nodes = Array.from(allIps).map(line => {
        if (!line.trim()) return null;
        const [addressPort, ...remarkParts] = line.split('#');
        const remark = remarkParts.join('#') || '優选节点';

        if (!addressPort.includes(':')) return null;

        const [address, port] = addressPort.split(':');
        return `vless://${uuid}@${address.trim()}:${port.trim()}?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=%2F#${encodeURIComponent(remark.trim())}`;
    }).filter(Boolean);

    const result = nodes.join('\n');
    return new Response(btoa(result), {
        headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'no-store'
        }
    });
}

/**
 * 处理 WARP Endpoint 查询 (/warp)
 */
async function handleWarpRequest(request, env) {
    let warpContent = '';
    if (env.KV) {
        warpContent = await env.KV.get('WARP.txt') || '';
    }

    if (!warpContent.trim()) {
        warpContent = '# 暂无保存的 Cloudflare WARP 优选端点，请通过 warp_tester.py 或管理后台添加\n162.159.197.2:4500#WARP-Default\n162.159.197.2:500#WARP-Default';
    }

    return new Response(warpContent, {
        headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'no-store'
        }
    });
}

/**
 * 处理 API 更新 (PUT /api/update)
 */
async function handleApiUpdate(request, env) {
    if (request.method !== 'PUT') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const url = new URL(request.url);
    const token = request.headers.get('Authorization') || url.searchParams.get('token');
    const mode = url.searchParams.get('mode'); // 'append' 或 overwrite
    const targetType = url.searchParams.get('type') || 'ips'; // 'warp' 或 'ips'

    if (!env.TOKEN) {
        return new Response('Unauthorized: TOKEN environment variable not set', { status: 401 });
    }
    if (token !== env.TOKEN) {
        return new Response('Unauthorized: Invalid token', { status: 401 });
    }

    let content = '';
    const contentType = request.headers.get('Content-Type') || '';

    if (contentType.includes('multipart/form-data')) {
        const formData = await request.formData();
        const file = formData.get('file');
        if (file && typeof file !== 'string') {
            content = await file.text();
        } else if (typeof file === 'string') {
            content = file;
        }
    } else {
        content = await request.text();
    }

    if (env.KV) {
        const invalidLines = validateProxyList(content);
        if (invalidLines.length > 0) {
            return new Response('Invalid format in lines:\n' + invalidLines.join('\n'), { status: 400 });
        }

        const isWarp = targetType === 'warp';
        const storageKey = isWarp ? 'WARP.txt' : 'ADD.txt';
        const timeKey = isWarp ? 'WARP_UPDATE_TIME' : 'UPDATE_TIME';
        const historyKey = isWarp ? 'WARP_HISTORY.json' : 'HISTORY.json';

        let finalContent = content;
        if (mode === 'append') {
            const existing = await env.KV.get(storageKey) || '';
            finalContent = existing + (existing && !existing.endsWith('\n') ? '\n' : '') + content;
        } else {
            // 覆盖模式：记录原有数据到历史记录
            const existing = await env.KV.get(storageKey) || '';
            await saveHistoryRecord(env, existing, historyKey);
        }
        await env.KV.put(storageKey, finalContent);
        await env.KV.put(timeKey, new Date().toISOString());
        return new Response(`Updated successfully (${isWarp ? 'WARP' : 'CDN'} ${mode === 'append' ? 'Appended' : 'Overwritten'})`, { status: 200 });
    } else {
        return new Response('KV not bound', { status: 500 });
    }
}

/**
 * 处理 API 历史记录查询 (GET /api/history)
 */
async function handleApiHistory(request, env) {
    if (request.method !== 'GET') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const url = new URL(request.url);
    const token = request.headers.get('Authorization') || url.searchParams.get('token');
    const cookie = request.headers.get('Cookie') || '';
    const isAuthByCookie = env.ADMIN && cookie.includes(`auth=${env.ADMIN}`);
    const isAuthByToken = env.TOKEN && token === env.TOKEN;
    const targetType = url.searchParams.get('type') || 'ips';

    if (env.TOKEN && !isAuthByToken && !isAuthByCookie) {
        return new Response(JSON.stringify({ success: false, message: 'Unauthorized: Invalid token or login required' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json; charset=utf-8' }
        });
    }

    const historyKey = targetType === 'warp' ? 'WARP_HISTORY.json' : 'HISTORY.json';
    let history = [];
    if (env.KV) {
        try {
            const raw = await env.KV.get(historyKey);
            if (raw) history = JSON.parse(raw);
        } catch (e) {
            history = [];
        }
    }

    return new Response(JSON.stringify({
        success: true,
        type: targetType,
        count: history.length,
        data: history
    }, null, 2), {
        headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Cache-Control': 'no-store'
        }
    });
}

/**
 * 保存历史记录函数 (最多支持 5 次记录，并且历史记录同一个 IP 全局去重)
 */
async function saveHistoryRecord(env, oldContent, historyKey = 'HISTORY.json') {
    if (!oldContent || !oldContent.trim()) return;

    const oldLines = splitLines(oldContent);
    if (oldLines.length === 0) return;

    // 1. 本次历史记录内部去重
    const uniqueNewIps = Array.from(new Set(oldLines));

    // 2. 读取现有历史记录
    let history = [];
    try {
        const raw = await env.KV.get(historyKey);
        if (raw) history = JSON.parse(raw);
    } catch (e) {
        history = [];
    }

    if (!Array.isArray(history)) history = [];

    // 若最新的历史记录内容与本次完全相同，跳过重复写入
    if (history.length > 0 && JSON.stringify(history[0].ips) === JSON.stringify(uniqueNewIps)) {
        return;
    }

    // 3. 跨历史记录去重：移除旧记录中与本次记录重复的 IP
    const newIpSet = new Set(uniqueNewIps);
    for (let i = 0; i < history.length; i++) {
        if (history[i] && Array.isArray(history[i].ips)) {
            history[i].ips = history[i].ips.filter(ip => !newIpSet.has(ip));
        }
    }

    // 过滤掉因为去重变为空的旧历史记录
    history = history.filter(item => item && Array.isArray(item.ips) && item.ips.length > 0);

    // 4. 将新历史记录插入到最前
    history.unshift({
        time: new Date().toISOString(),
        ips: uniqueNewIps
    });

    // 5. 限制最多保留 5 次历史记录
    if (history.length > 5) {
        history = history.slice(0, 5);
    }

    // 6. 保存回 KV
    await env.KV.put(historyKey, JSON.stringify(history));
}

/**
 * 处理后台管理 (/admin)
 */
async function handleAdminRequest(request, env) {
    const adminPassword = env.ADMIN;
    if (!adminPassword) {
        return new Response('ADMIN password not set in environment variables', { status: 500 });
    }

    const cookie = request.headers.get('Cookie') || '';
    const isAuth = cookie.includes(`auth=${adminPassword}`);

    if (request.method === 'POST') {
        const formData = await request.formData();
        const password = formData.get('password');
        const action = formData.get('action');

        if (action === 'login') {
            if (password === adminPassword) {
                return new Response('Login success', {
                    status: 302,
                    headers: {
                        'Set-Cookie': `auth=${adminPassword}; HttpOnly; Path=/; Max-Age=86400`,
                        'Location': '/admin'
                    }
                });
            } else {
                return new Response('Invalid password', { status: 401 });
            }
        }

        if (isAuth && (action === 'save_cdn' || action === 'save_warp' || action === 'save')) {
            const content = formData.get('content') || '';
            const mode = formData.get('mode');
            const targetType = (action === 'save_warp' || formData.get('type') === 'warp') ? 'warp' : 'cdn';

            if (env.KV) {
                const invalidLines = validateProxyList(content);
                if (invalidLines.length > 0) {
                    return new Response('格式错误:\n' + invalidLines.join('\n'), { status: 400 });
                }

                const isWarp = targetType === 'warp';
                const storageKey = isWarp ? 'WARP.txt' : 'ADD.txt';
                const timeKey = isWarp ? 'WARP_UPDATE_TIME' : 'UPDATE_TIME';
                const historyKey = isWarp ? 'WARP_HISTORY.json' : 'HISTORY.json';

                let finalContent = content;
                if (mode === 'append') {
                    const existing = await env.KV.get(storageKey) || '';
                    finalContent = existing + (existing && !existing.endsWith('\n') ? '\n' : '') + content;
                } else {
                    const existing = await env.KV.get(storageKey) || '';
                    await saveHistoryRecord(env, existing, historyKey);
                }
                await env.KV.put(storageKey, finalContent);
                await env.KV.put(timeKey, new Date().toISOString());
                return new Response(`Saved ${isWarp ? 'WARP' : 'CDN'} successfully`, { status: 200 });
            }
        }
    }

    if (!isAuth) {
        return new Response(renderLoginPage(), { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }

    // 获取 CDN 数据
    const cdnIps = env.KV ? await env.KV.get('ADD.txt') || '' : '';
    const cdnUpdateTime = env.KV ? await env.KV.get('UPDATE_TIME') || '' : '';
    let cdnHistory = [];
    if (env.KV) {
        try {
            const raw = await env.KV.get('HISTORY.json');
            if (raw) cdnHistory = JSON.parse(raw);
        } catch (e) {
            cdnHistory = [];
        }
    }

    // 获取 WARP 数据
    const warpEndpoints = env.KV ? await env.KV.get('WARP.txt') || '' : '';
    const warpUpdateTime = env.KV ? await env.KV.get('WARP_UPDATE_TIME') || '' : '';
    let warpHistory = [];
    if (env.KV) {
        try {
            const raw = await env.KV.get('WARP_HISTORY.json');
            if (raw) warpHistory = JSON.parse(raw);
        } catch (e) {
            warpHistory = [];
        }
    }

    return new Response(renderAdminPage({
        cdnIps,
        cdnUpdateTime,
        cdnHistory,
        warpEndpoints,
        warpUpdateTime,
        warpHistory
    }), { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

function splitLines(str) {
    return (str || '').split(/\r?\n/).map(l => l.trim()).filter(l => l && !l.startsWith('//'));
}

function validateProxyList(content) {
    const lines = splitLines(content);
    const invalidLines = [];
    for (const line of lines) {
        if (/^[a-z0-9-]+:\/\//i.test(line)) {
            continue;
        }

        const [addressPort] = line.split('#');
        if (!addressPort.includes(':')) {
            invalidLines.push(`"${line}" (缺少端口，需为 IP:端口 格式)`);
            continue;
        }

        const parts = addressPort.split(':');
        const portStr = parts[parts.length - 1].trim();
        const port = parseInt(portStr);

        if (isNaN(port) || port <= 0 || port > 65535) {
            invalidLines.push(`"${line}" (端口无效: ${portStr})`);
        }
    }
    return invalidLines;
}

function isValidBase64(str) {
    if (typeof str !== 'string') return false;
    const cleanStr = str.replace(/\s/g, '');
    if (cleanStr.length === 0 || cleanStr.length % 4 !== 0) return false;
    const base64Regex = /^[A-Za-z0-9+/]+={0,2}$/;
    if (!base64Regex.test(cleanStr)) return false;
    try {
        atob(cleanStr);
        return true;
    } catch {
        return false;
    }
}

function base64Decode(str) {
    const bytes = new Uint8Array(atob(str).split('').map(c => c.charCodeAt(0)));
    const decoder = new TextDecoder('utf-8');
    return decoder.decode(bytes);
}

function escapeHtml(str) {
    if (typeof str !== 'string') return '';
    return str.replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;')
              .replace(/'/g, '&#039;');
}

// --- UI Templates ---

function renderLoginPage() {
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>登录 - 优选节点与 WARP 管理后台</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: #6366f1;
            --primary-hover: #4f46e5;
            --primary-glow: rgba(99, 102, 241, 0.35);
            --bg: #0b0f19;
            --card-bg: rgba(20, 27, 45, 0.75);
            --border: rgba(255, 255, 255, 0.12);
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            background: var(--bg);
            background-image: 
                radial-gradient(circle at 15% 15%, rgba(99, 102, 241, 0.15), transparent 40%),
                radial-gradient(circle at 85% 85%, rgba(192, 132, 252, 0.12), transparent 40%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #f1f5f9;
            overflow: hidden;
        }
        .login-card {
            background: var(--card-bg);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid var(--border);
            padding: 2.75rem 2.25rem;
            border-radius: 1.75rem;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6), 0 0 40px var(--primary-glow);
            width: 100%;
            max-width: 420px;
            animation: cardAppear 0.6s cubic-bezier(0.16, 1, 0.3, 1);
            position: relative;
        }
        @keyframes cardAppear {
            from { opacity: 0; transform: translateY(24px) scale(0.96); }
            to { opacity: 1; transform: translateY(0) scale(1); }
        }
        .brand-icon {
            width: 56px;
            height: 56px;
            background: linear-gradient(135deg, #6366f1, #a855f7);
            border-radius: 1rem;
            display: flex;
            align-items: center;
            justify-content: center;
            margin: 0 auto 1.25rem;
            box-shadow: 0 10px 20px -5px rgba(99, 102, 241, 0.5);
        }
        .brand-icon svg { width: 28px; height: 28px; fill: none; stroke: white; stroke-width: 2; }
        h1 {
            font-size: 1.5rem;
            font-weight: 800;
            text-align: center;
            margin-bottom: 0.5rem;
            background: linear-gradient(135deg, #a5b4fc, #c084fc, #38bdf8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .subtitle {
            text-align: center;
            color: #94a3b8;
            font-size: 0.875rem;
            margin-bottom: 2rem;
        }
        .form-group { margin-bottom: 1.5rem; }
        label { display: block; font-size: 0.8rem; font-weight: 600; color: #cbd5e1; margin-bottom: 0.5rem; text-transform: uppercase; letter-spacing: 0.05em; }
        input[type="password"] {
            width: 100%;
            padding: 0.875rem 1.25rem;
            border-radius: 0.875rem;
            border: 1px solid var(--border);
            background: rgba(11, 15, 25, 0.7);
            color: white;
            font-size: 0.95rem;
            transition: all 0.25s ease;
        }
        input[type="password"]:focus {
            outline: none;
            border-color: var(--primary);
            box-shadow: 0 0 0 4px var(--primary-glow);
            background: rgba(15, 23, 42, 0.9);
        }
        button[type="submit"] {
            width: 100%;
            padding: 0.875rem;
            border-radius: 0.875rem;
            border: none;
            background: linear-gradient(135deg, #6366f1, #4f46e5);
            color: white;
            font-size: 0.95rem;
            font-weight: 700;
            cursor: pointer;
            transition: all 0.3s ease;
            box-shadow: 0 8px 16px -4px rgba(99, 102, 241, 0.4);
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 0.5rem;
        }
        button[type="submit"]:hover {
            transform: translateY(-2px);
            box-shadow: 0 12px 24px -4px rgba(99, 102, 241, 0.6);
            background: linear-gradient(135deg, #4f46e5, #4338ca);
        }
        button[type="submit"]:active { transform: translateY(0); }
    </style>
</head>
<body>
    <div class="login-card">
        <div class="brand-icon">
            <svg viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/></svg>
        </div>
        <h1>Preferred IP Manager</h1>
        <p class="subtitle">Cloudflare CDN 优选与 WARP Endpoint 聚合管理后台</p>
        <form method="POST" action="/admin">
            <input type="hidden" name="action" value="login">
            <div class="form-group">
                <label>ADMIN 登录密码</label>
                <input type="password" name="password" placeholder="••••••••••••" required autofocus autocomplete="current-password">
            </div>
            <button type="submit">
                <span>立即登录后台</span>
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24" style="stroke-width:2.5;"><path stroke-linecap="round" stroke-linejoin="round" d="M13.5 4.5L21 12m0 0l-7.5 7.5M21 12H3"/></svg>
            </button>
        </form>
    </div>
</body>
</html>`;
}

function renderAdminPage(data) {
    const { cdnIps, cdnUpdateTime, cdnHistory, warpEndpoints, warpUpdateTime, warpHistory } = data;

    function formatTime(isoStr) {
        if (!isoStr) return '暂无记录';
        try {
            return new Intl.DateTimeFormat('zh-CN', {
                year: 'numeric', month: '2-digit', day: '2-digit',
                hour: '2-digit', minute: '2-digit', second: '2-digit',
                timeZone: 'Asia/Shanghai'
            }).format(new Date(isoStr));
        } catch {
            return isoStr;
        }
    }

    const cdnCount = splitLines(cdnIps).length;
    const warpCount = splitLines(warpEndpoints).length;

    function renderHistoryList(historyArray, type) {
        if (!historyArray || historyArray.length === 0) {
            return `
            <div class="empty-history">
                <svg width="48" height="48" fill="none" stroke="currentColor" viewBox="0 0 24 24" style="opacity:0.3; margin-bottom: 0.75rem; stroke-width: 1.5;"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <div style="font-weight: 600; font-size: 0.95rem; margin-bottom: 0.25rem;">暂无 ${type === 'warp' ? 'WARP' : 'CDN'} 历史备份</div>
                <div style="font-size: 0.8rem; color: var(--text-muted);">使用覆盖模式保存时，旧记录会自动保存至此处（最多 5 份）</div>
            </div>`;
        }

        return historyArray.map((item, idx) => {
            const ipListText = (item.ips || []).join('\n');
            const ipCount = (item.ips || []).length;
            const timeStr = formatTime(item.time);
            return `
            <div class="history-card">
                <div class="history-header">
                    <div class="history-info">
                        <span class="history-tag">${idx === 0 ? '最新备份' : `#${idx + 1}`}</span>
                        <span class="history-time">
                            <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                            ${timeStr}
                        </span>
                        <span class="history-badge">${ipCount} 个 ${type === 'warp' ? '端点' : 'IP'}</span>
                    </div>
                    <div class="history-actions">
                        <button class="btn btn-xs btn-outline" onclick="copyText(\`${encodeURIComponent(ipListText)}\`)">
                            <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                            复制
                        </button>
                        <button class="btn btn-xs btn-primary" onclick="restoreHistory('${type}', \`${encodeURIComponent(ipListText)}\`)">
                            <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/></svg>
                            导入至编辑器
                        </button>
                    </div>
                </div>
                <pre class="history-code">${escapeHtml(ipListText)}</pre>
            </div>`;
        }).join('');
    }

    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>管理后台 - Preferred IP Manager</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: #6366f1;
            --primary-hover: #4f46e5;
            --primary-glow: rgba(99, 102, 241, 0.35);
            --warp-color: #f59e0b;
            --warp-glow: rgba(245, 158, 11, 0.35);
            --success: #10b981;
            --success-glow: rgba(16, 185, 129, 0.3);
            --danger: #ef4444;
            --bg: #0b0f19;
            --card-bg: rgba(20, 27, 45, 0.75);
            --input-bg: rgba(11, 15, 25, 0.7);
            --border: rgba(255, 255, 255, 0.1);
            --border-hover: rgba(255, 255, 255, 0.2);
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            background: var(--bg);
            background-image: 
                radial-gradient(circle at 10% 10%, rgba(99, 102, 241, 0.12), transparent 35%),
                radial-gradient(circle at 90% 90%, rgba(245, 158, 11, 0.1), transparent 35%);
            min-height: 100vh;
            color: var(--text-main);
            padding: 2rem 1.5rem;
        }
        .container { max-width: 1024px; margin: 0 auto; }
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 2rem;
            flex-wrap: wrap;
            gap: 1rem;
        }
        .brand-section { display: flex; align-items: center; gap: 1rem; }
        .brand-logo {
            width: 44px;
            height: 44px;
            background: linear-gradient(135deg, #6366f1, #f59e0b);
            border-radius: 0.85rem;
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 8px 16px -4px var(--primary-glow);
        }
        .brand-logo svg { width: 24px; height: 24px; fill: none; stroke: white; stroke-width: 2.2; }
        h1 {
            font-size: 1.4rem;
            font-weight: 800;
            background: linear-gradient(135deg, #a5b4fc, #fcd34d, #38bdf8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .status-pill {
            display: inline-flex;
            align-items: center;
            gap: 0.4rem;
            font-size: 0.75rem;
            font-weight: 600;
            color: #34d399;
            background: rgba(16, 185, 129, 0.12);
            border: 1px solid rgba(16, 185, 129, 0.25);
            padding: 0.2rem 0.6rem;
            border-radius: 2rem;
            margin-top: 0.25rem;
        }
        .pulse-dot {
            width: 6px; height: 6px;
            background: #10b981;
            border-radius: 50%;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
            70% { box-shadow: 0 0 0 6px rgba(16, 185, 129, 0); }
            100% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
        }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1rem;
            margin-bottom: 1.75rem;
        }
        .stat-card {
            background: var(--card-bg);
            backdrop-filter: blur(16px);
            border: 1px solid var(--border);
            padding: 1.1rem 1.4rem;
            border-radius: 1.25rem;
            display: flex;
            align-items: center;
            justify-content: space-between;
            transition: all 0.3s ease;
        }
        .stat-card:hover { border-color: var(--border-hover); transform: translateY(-2px); }
        .stat-label { font-size: 0.8rem; font-weight: 500; color: var(--text-muted); margin-bottom: 0.25rem; }
        .stat-val { font-size: 1.35rem; font-weight: 800; color: white; font-family: 'Fira Code', monospace; }
        .stat-icon {
            width: 38px; height: 38px;
            border-radius: 0.75rem;
            background: rgba(255, 255, 255, 0.05);
            display: flex;
            align-items: center;
            justify-content: center;
            color: #818cf8;
        }
        .stat-icon.warp { color: #f59e0b; }
        .stat-icon svg { width: 20px; height: 20px; stroke-width: 2; }
        .card {
            background: var(--card-bg);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid var(--border);
            padding: 2rem;
            border-radius: 1.75rem;
            box-shadow: 0 20px 40px -15px rgba(0, 0, 0, 0.5);
        }
        .main-tabs {
            display: flex;
            gap: 0.75rem;
            margin-bottom: 1.75rem;
            border-bottom: 1px solid var(--border);
            padding-bottom: 0.75rem;
            flex-wrap: wrap;
        }
        .tab-btn {
            padding: 0.65rem 1.25rem;
            border-radius: 0.85rem;
            border: 1px solid transparent;
            background: transparent;
            color: var(--text-muted);
            font-size: 0.9rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.25s ease;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .tab-btn:hover { color: white; background: rgba(255, 255, 255, 0.05); }
        .tab-btn.active {
            color: white;
            background: linear-gradient(135deg, rgba(99, 102, 241, 0.25), rgba(168, 85, 247, 0.2));
            border-color: rgba(99, 102, 241, 0.4);
            box-shadow: 0 4px 12px rgba(99, 102, 241, 0.15);
        }
        .tab-btn.active.warp-tab {
            background: linear-gradient(135deg, rgba(245, 158, 11, 0.25), rgba(217, 119, 6, 0.2));
            border-color: rgba(245, 158, 11, 0.4);
            box-shadow: 0 4px 12px rgba(245, 158, 11, 0.15);
        }
        .label-group {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.85rem;
            flex-wrap: wrap;
            gap: 0.75rem;
        }
        .label { color: var(--text-muted); font-size: 0.85rem; font-weight: 500; display: flex; align-items: center; gap: 0.4rem; }
        .mode-selector {
            display: flex;
            background: var(--input-bg);
            padding: 0.25rem;
            border-radius: 0.85rem;
            border: 1px solid var(--border);
        }
        .mode-option {
            padding: 0.35rem 0.9rem;
            border-radius: 0.65rem;
            font-size: 0.8rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.25s ease;
            color: var(--text-muted);
        }
        .mode-option.active {
            background: #222c44;
            color: #f1f5f9;
            box-shadow: 0 2px 6px rgba(0, 0, 0, 0.3);
        }
        .editor-container { position: relative; margin-bottom: 1.5rem; }
        textarea {
            width: 100%;
            height: 320px;
            background: var(--input-bg);
            border: 1px solid var(--border);
            border-radius: 1.25rem;
            padding: 1.25rem 1.5rem;
            color: #e2e8f0;
            font-family: 'Fira Code', monospace;
            font-size: 0.9rem;
            line-height: 1.6;
            resize: vertical;
            transition: all 0.25s ease;
        }
        textarea:focus {
            outline: none;
            border-color: var(--primary);
            box-shadow: 0 0 0 4px var(--primary-glow);
        }
        .btn {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 0.5rem;
            padding: 0.75rem 1.4rem;
            border-radius: 0.85rem;
            font-weight: 600;
            font-size: 0.875rem;
            cursor: pointer;
            transition: all 0.25s ease;
            border: none;
        }
        .btn-primary {
            background: linear-gradient(135deg, #6366f1, #4f46e5);
            color: white;
            box-shadow: 0 4px 12px -2px rgba(99, 102, 241, 0.4);
        }
        .btn-primary:hover { transform: translateY(-1px); box-shadow: 0 8px 20px -4px rgba(99, 102, 241, 0.6); }
        .btn-warp {
            background: linear-gradient(135deg, #f59e0b, #d97706);
            color: white;
            box-shadow: 0 4px 12px -2px var(--warp-glow);
        }
        .btn-warp:hover { transform: translateY(-1px); box-shadow: 0 8px 20px -4px rgba(245, 158, 11, 0.6); }
        .btn-outline {
            background: rgba(255, 255, 255, 0.05);
            color: #cbd5e1;
            border: 1px solid var(--border);
        }
        .btn-outline:hover { background: rgba(255, 255, 255, 0.1); color: white; }
        .btn-xs { padding: 0.35rem 0.75rem; font-size: 0.75rem; border-radius: 0.6rem; }
        .action-bar { display: flex; justify-content: flex-end; gap: 0.75rem; flex-wrap: wrap; }
        .history-card {
            background: rgba(11, 15, 25, 0.6);
            border: 1px solid var(--border);
            border-radius: 1rem;
            padding: 1rem 1.25rem;
            margin-bottom: 1rem;
        }
        .history-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.75rem;
            flex-wrap: wrap;
            gap: 0.5rem;
        }
        .history-info { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
        .history-tag {
            background: rgba(99, 102, 241, 0.2);
            color: #a5b4fc;
            padding: 0.15rem 0.5rem;
            border-radius: 0.4rem;
            font-size: 0.75rem;
            font-weight: 700;
        }
        .history-time { font-size: 0.8rem; color: var(--text-muted); display: flex; align-items: center; gap: 0.3rem; }
        .history-badge { background: rgba(255, 255, 255, 0.05); padding: 0.15rem 0.5rem; border-radius: 0.4rem; font-size: 0.75rem; color: #cbd5e1; }
        .history-code {
            background: rgba(0, 0, 0, 0.35);
            padding: 0.85rem;
            border-radius: 0.65rem;
            font-family: 'Fira Code', monospace;
            font-size: 0.8rem;
            color: #94a3b8;
            max-height: 140px;
            overflow-y: auto;
            white-space: pre-wrap;
        }
        .config-box {
            background: rgba(0, 0, 0, 0.4);
            border: 1px solid var(--border);
            border-radius: 1rem;
            padding: 1.25rem;
            margin-bottom: 1.25rem;
        }
        .config-title { font-weight: 700; font-size: 0.95rem; margin-bottom: 0.5rem; display: flex; align-items: center; justify-content: space-between; color: #fcd34d; }
        .api-note {
            background: rgba(99, 102, 241, 0.08);
            border: 1px solid rgba(99, 102, 241, 0.2);
            border-radius: 1rem;
            padding: 1rem;
            margin-top: 1.5rem;
            font-size: 0.85rem;
            color: #cbd5e1;
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }
        .api-note code {
            background: rgba(0, 0, 0, 0.3);
            padding: 0.2rem 0.4rem;
            border-radius: 0.3rem;
            color: #818cf8;
            font-family: 'Fira Code', monospace;
        }
        #toast {
            position: fixed;
            bottom: 2rem;
            right: 2rem;
            background: var(--success);
            color: white;
            padding: 0.85rem 1.4rem;
            border-radius: 1rem;
            font-weight: 600;
            font-size: 0.875rem;
            box-shadow: 0 10px 25px -3px var(--success-glow);
            opacity: 0;
            transform: translateY(20px);
            transition: all 0.3s ease;
            pointer-events: none;
            z-index: 100;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        #toast.show { opacity: 1; transform: translateY(0); }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="brand-section">
                <div class="brand-logo">
                    <svg viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
                </div>
                <div>
                    <h1>Preferred IP & WARP Manager</h1>
                    <span class="status-pill">
                        <span class="pulse-dot"></span>
                        Worker 运行正常
                    </span>
                </div>
            </div>
            <div>
                <a href="/login" class="btn btn-outline btn-xs" onclick="document.cookie='auth=; Max-Age=0; path=/'; location.reload(); return false;">退出登录</a>
            </div>
        </header>

        <div class="stats-grid">
            <div class="stat-card">
                <div>
                    <div class="stat-label">CDN 优选 IP 数量</div>
                    <div class="stat-val" id="cdnCountVal">${cdnCount}</div>
                </div>
                <div class="stat-icon">
                    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 104 0 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064"/></svg>
                </div>
            </div>
            <div class="stat-card">
                <div>
                    <div class="stat-label">CDN 最近同步时间</div>
                    <div class="stat-val" style="font-size: 0.95rem;">${formatTime(cdnUpdateTime)}</div>
                </div>
                <div class="stat-icon">
                    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                </div>
            </div>
            <div class="stat-card">
                <div>
                    <div class="stat-label">WARP 优选端点数</div>
                    <div class="stat-val" id="warpCountVal" style="color: #fcd34d;">${warpCount}</div>
                </div>
                <div class="stat-icon warp">
                    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
                </div>
            </div>
            <div class="stat-card">
                <div>
                    <div class="stat-label">WARP 最近测速更新</div>
                    <div class="stat-val" style="font-size: 0.95rem; color: #fcd34d;">${formatTime(warpUpdateTime)}</div>
                </div>
                <div class="stat-icon warp">
                    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                </div>
            </div>
        </div>

        <div class="card">
            <div class="main-tabs">
                <button class="tab-btn active" id="tabCdn" onclick="switchMainTab('cdn')">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"/></svg>
                    CDN 优选 IP (${cdnCount})
                </button>
                <button class="tab-btn warp-tab" id="tabWarp" onclick="switchMainTab('warp')">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
                    WARP 优选 Endpoint (${warpCount})
                </button>
                <button class="tab-btn" id="tabHistory" onclick="switchMainTab('history')">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                    历史备份记录
                </button>
                <button class="tab-btn" id="tabExport" onclick="switchMainTab('export')">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7v8a2 2 0 002 2h6M8 7V5a2 2 0 012-2h4.586a1 1 0 01.707.293l4.414 4.414a1 1 0 01.293.707V15a2 2 0 01-2 2h-2M8 7H6a2 2 0 00-2 2v10a2 2 0 002 2h8a2 2 0 002-2v-2"/></svg>
                    客户端配置生成
                </button>
            </div>

            <!-- CDN 优选 IP 面板 -->
            <div id="panelCdn">
                <div class="label-group">
                    <span class="label">
                        <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>
                        编辑 CDN 优选 IP 列表 (格式: IP:端口#备注)
                    </span>
                    <div class="mode-selector">
                        <span class="mode-option active" data-mode="overwrite" onclick="setMode('cdn', 'overwrite')">覆盖模式</span>
                        <span class="mode-option" data-mode="append" onclick="setMode('cdn', 'append')">追加模式</span>
                    </div>
                </div>
                <div class="editor-container">
                    <textarea id="cdnContent" placeholder="例如: 104.16.80.1:443#Cloudflare" oninput="updateCounter('cdn')">${escapeHtml(cdnIps)}</textarea>
                </div>
                <div class="action-bar">
                    <button class="btn btn-outline" onclick="copyContent('cdnContent')">复制全部</button>
                    <button class="btn btn-primary" id="saveCdnBtn" onclick="saveData('cdn')">保存 CDN 更改</button>
                </div>
                <div class="api-note">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                    <span><strong>订阅与同步:</strong> VLESS 订阅地址为 <code>/sub?host=YOUR_HOST&uuid=YOUR_UUID</code>；Python 测速脚本可通过 <code>process_ips.py --target cdn</code> 自动推送。</span>
                </div>
            </div>

            <!-- WARP 优选 Endpoint 面板 -->
            <div id="panelWarp" style="display: none;">
                <div class="label-group">
                    <span class="label" style="color: #fcd34d;">
                        <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
                        编辑 Cloudflare WARP 优选端点 (格式: IP:端口#备注)
                    </span>
                    <div class="mode-selector">
                        <span class="mode-option active" data-mode="overwrite" onclick="setMode('warp', 'overwrite')">覆盖模式</span>
                        <span class="mode-option" data-mode="append" onclick="setMode('warp', 'append')">追加模式</span>
                    </div>
                </div>
                <div class="editor-container">
                    <textarea id="warpContent" placeholder="例如: 162.159.197.2:4500#WARP-HK" oninput="updateCounter('warp')">${escapeHtml(warpEndpoints)}</textarea>
                </div>
                <div class="action-bar">
                    <button class="btn btn-outline" onclick="copyContent('warpContent')">复制全部</button>
                    <button class="btn btn-warp" id="saveWarpBtn" onclick="saveData('warp')">保存 WARP 更改</button>
                </div>
                <div class="api-note">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
                    <span><strong>WARP 接口与测速:</strong> 原始端点接口为 <code>/warp</code>；本地测速推送可通过 <code>python process_ips.py --target warp</code> 或 <code>warp_tester.py</code> 一键完成。</span>
                </div>
            </div>

            <!-- 历史备份记录面板 -->
            <div id="panelHistory" style="display: none;">
                <div style="display: flex; gap: 0.5rem; margin-bottom: 1.25rem;">
                    <button class="btn btn-xs btn-outline active" id="btnHistCdn" onclick="switchHistType('cdn')">CDN 历史记录 (${cdnHistory.length})</button>
                    <button class="btn btn-xs btn-outline" id="btnHistWarp" onclick="switchHistType('warp')">WARP 历史记录 (${warpHistory.length})</button>
                </div>
                <div id="histCdnList">
                    ${renderHistoryList(cdnHistory, 'cdn')}
                </div>
                <div id="histWarpList" style="display: none;">
                    ${renderHistoryList(warpHistory, 'warp')}
                </div>
            </div>

            <!-- 客户端配置生成面板 -->
            <div id="panelExport" style="display: none;">
                <div class="config-box">
                    <div class="config-title">
                        <span>WireGuard / WARP 客户端配置格式</span>
                        <button class="btn btn-xs btn-outline" onclick="copyGenerated('wg')">复制 WireGuard 片段</button>
                    </div>
                    <pre class="history-code" id="codeWg"></pre>
                </div>

                <div class="config-box">
                    <div class="config-title">
                        <span>Sing-box Outbound JSON 配置片段</span>
                        <button class="btn btn-xs btn-outline" onclick="copyGenerated('singbox')">复制 Sing-box 片段</button>
                    </div>
                    <pre class="history-code" id="codeSingbox"></pre>
                </div>

                <div class="config-box">
                    <div class="config-title">
                        <span>Clash Meta / Mihomo Proxies YAML 配置片段</span>
                        <button class="btn btn-xs btn-outline" onclick="copyGenerated('clash')">复制 Clash 片段</button>
                    </div>
                    <pre class="history-code" id="codeClash"></pre>
                </div>

                <div class="config-box">
                    <div class="config-title">
                        <span>WARP-CLI 终端切换命令</span>
                        <button class="btn btn-xs btn-outline" onclick="copyGenerated('warpcli')">复制 CLI 命令</button>
                    </div>
                    <pre class="history-code" id="codeWarpCli"></pre>
                </div>
            </div>
        </div>
    </div>

    <div id="toast">
        <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5 13l4 4L19 7"/></svg>
        <span id="toastMsg">操作成功！</span>
    </div>

    <script>
        let currentMode = { cdn: 'overwrite', warp: 'overwrite' };

        function switchMainTab(tab) {
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            ['Cdn', 'Warp', 'History', 'Export'].forEach(t => {
                const el = document.getElementById('panel' + t);
                if (el) el.style.display = 'none';
            });

            if (tab === 'cdn') {
                document.getElementById('tabCdn').classList.add('active');
                document.getElementById('panelCdn').style.display = 'block';
            } else if (tab === 'warp') {
                document.getElementById('tabWarp').classList.add('active');
                document.getElementById('panelWarp').style.display = 'block';
            } else if (tab === 'history') {
                document.getElementById('tabHistory').classList.add('active');
                document.getElementById('panelHistory').style.display = 'block';
            } else if (tab === 'export') {
                document.getElementById('tabExport').classList.add('active');
                document.getElementById('panelExport').style.display = 'block';
                generateExportConfigs();
            }
        }

        function switchHistType(type) {
            document.getElementById('btnHistCdn').classList.toggle('active', type === 'cdn');
            document.getElementById('btnHistWarp').classList.toggle('active', type === 'warp');
            document.getElementById('histCdnList').style.display = (type === 'cdn' ? 'block' : 'none');
            document.getElementById('histWarpList').style.display = (type === 'warp' ? 'block' : 'none');
        }

        function setMode(target, mode) {
            currentMode[target] = mode;
            const panel = document.getElementById(target === 'warp' ? 'panelWarp' : 'panelCdn');
            panel.querySelectorAll('.mode-option').forEach(opt => {
                opt.classList.toggle('active', opt.dataset.mode === mode);
            });
        }

        function updateCounter(target) {
            const val = document.getElementById(target === 'warp' ? 'warpContent' : 'cdnContent').value;
            const lines = val.split(/\\r?\\n/).map(l => l.trim()).filter(l => l && !l.startsWith('//') && l.includes(':'));
            if (target === 'warp') {
                document.getElementById('warpCountVal').innerText = lines.length;
            } else {
                document.getElementById('cdnCountVal').innerText = lines.length;
            }
        }

        function copyContent(elemId) {
            const val = document.getElementById(elemId).value;
            if (!val.trim()) {
                showToast('内容为空！', true);
                return;
            }
            navigator.clipboard.writeText(val).then(() => {
                showToast('已复制内容到剪贴板！');
            }).catch(e => showToast('复制失败: ' + e, true));
        }

        function copyText(encoded) {
            const text = decodeURIComponent(encoded);
            navigator.clipboard.writeText(text).then(() => {
                showToast('复制成功！');
            }).catch(e => showToast('复制失败: ' + e, true));
        }

        function restoreHistory(target, encoded) {
            const text = decodeURIComponent(encoded);
            if (target === 'warp') {
                switchMainTab('warp');
                setMode('warp', 'overwrite');
                document.getElementById('warpContent').value = text;
                updateCounter('warp');
            } else {
                switchMainTab('cdn');
                setMode('cdn', 'overwrite');
                document.getElementById('cdnContent').value = text;
                updateCounter('cdn');
            }
            showToast('已导入至编辑器，确认后请点击保存更改生效！');
        }

        async function saveData(target) {
            const isWarp = (target === 'warp');
            const textarea = document.getElementById(isWarp ? 'warpContent' : 'cdnContent');
            const btn = document.getElementById(isWarp ? 'saveWarpBtn' : 'saveCdnBtn');
            const mode = currentMode[target];

            btn.disabled = true;
            const orig = btn.innerHTML;
            btn.innerHTML = '正在保存...';

            try {
                const formData = new FormData();
                formData.append('action', isWarp ? 'save_warp' : 'save_cdn');
                formData.append('type', isWarp ? 'warp' : 'ips');
                formData.append('content', textarea.value);
                formData.append('mode', mode);

                const res = await fetch('/admin', { method: 'POST', body: formData });
                if (res.ok) {
                    showToast('保存成功 (旧记录已自动备份至历史)！');
                    setTimeout(() => location.reload(), 1000);
                } else {
                    const msg = await res.text();
                    showToast(msg, true);
                }
            } catch (e) {
                showToast('保存出错: ' + e.message, true);
            } finally {
                btn.disabled = false;
                btn.innerHTML = orig;
            }
        }

        function generateExportConfigs() {
            const warpVal = document.getElementById('warpContent').value;
            const lines = warpVal.split(/\\r?\\n/).map(l => l.trim()).filter(l => l && !l.startsWith('//') && l.includes(':'));
            
            const parsed = lines.map((l, i) => {
                const [addrPort, ...remarkParts] = l.split('#');
                const lastColon = addrPort.lastIndexOf(':');
                const ip = addrPort.substring(0, lastColon).trim();
                const port = parseInt(addrPort.substring(lastColon + 1).trim());
                const remark = remarkParts.join('#') || ('WARP-' + (i + 1));
                return { ip, port, remark };
            }).filter(e => e.ip && e.port);

            // WireGuard
            const wgLines = ['# Cloudflare WARP WireGuard Endpoints'];
            parsed.forEach((e, i) => {
                wgLines.push(\`# [\${i+1}] \${e.remark}\`);
                wgLines.push(\`Endpoint = \${e.ip}:\${e.port}\`);
            });
            document.getElementById('codeWg').innerText = wgLines.join('\\n');

            // Sing-box
            const sbOutbounds = parsed.map((e, i) => ({
                type: "wireguard",
                tag: e.remark || ("WARP-" + (i + 1)),
                server: e.ip,
                server_port: e.port,
                system_interface: false,
                mtu: 1280
            }));
            document.getElementById('codeSingbox').innerText = JSON.stringify(sbOutbounds, null, 2);

            // Clash
            const clashLines = ['# Clash Meta / Mihomo Proxies:'];
            parsed.forEach((e, i) => {
                clashLines.push(\`- name: "\${e.remark || ('WARP-' + (i+1))}"\`);
                clashLines.push(\`  type: wireguard\`);
                clashLines.push(\`  server: \${e.ip}\`);
                clashLines.push(\`  port: \${e.port}\`);
                clashLines.push(\`  ip: 172.16.0.2\`);
                clashLines.push(\`  public-key: bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\`);
                clashLines.push(\`  udp: true\`);
            });
            document.getElementById('codeClash').innerText = clashLines.join('\\n');

            // WARP-CLI
            const cliLines = ['# Cloudflare WARP-CLI 切换命令:'];
            parsed.forEach((e, i) => {
                cliLines.push(\`# [\${i+1}] \${e.remark}\`);
                cliLines.push(\`warp-cli tunnel endpoint set \${e.ip}:\${e.port}\`);
            });
            document.getElementById('codeWarpCli').innerText = cliLines.join('\\n');
        }

        function copyGenerated(type) {
            let elId = 'codeWg';
            if (type === 'singbox') elId = 'codeSingbox';
            if (type === 'clash') elId = 'codeClash';
            if (type === 'warpcli') elId = 'codeWarpCli';

            const val = document.getElementById(elId).innerText;
            navigator.clipboard.writeText(val).then(() => {
                showToast('已复制配置片段到剪贴板！');
            }).catch(e => showToast('复制失败: ' + e, true));
        }

        function showToast(msg, isError = false) {
            const toast = document.getElementById('toast');
            document.getElementById('toastMsg').innerText = msg;
            toast.style.background = isError ? 'var(--danger)' : 'var(--success)';
            toast.classList.add('show');
            setTimeout(() => toast.classList.remove('show'), 3500);
        }
    </script>
</body>
</html>`;
}
