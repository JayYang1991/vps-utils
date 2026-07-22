/**
 * edgetunnel 优选订阅管理 Worker
 * 功能：
 * 1. /sub 接口：返回加密的节点列表（合并远程与本地 KV 优选 IP）。
 * 2. /admin 接口：美观的管理后台，用于编辑本地优选 IP 及查看历史 IP 记录。
 * 3. /api/update 接口：支持 PUT 请求配合 Token 自动更新优选 IP。
 * 4. /api/history 接口：支持 GET 请求查询历史优选 IP 记录。
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

        // 2. 自动化 API 更新接口 /api/update (支持 PUT)
        if (path === '/api/update') {
            return await handleApiUpdate(request, env);
        }

        // 3. 历史记录 API 查询接口 /api/history (支持 GET)
        if (path === '/api/history') {
            return await handleApiHistory(request, env);
        }

        // 4. 管理后台 /admin
        if (path === '/admin' || path === '/login') {
            return await handleAdminRequest(request, env);
        }

        // 5. 默认返回
        return new Response('Not Found', { status: 404 });
    }
};

/**
 * 处理订阅请求
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
                const remarkMatch = line.match(/#(.+)$/);
                const remark = remarkMatch ? decodeURIComponent(remarkMatch[1]) : '';
                allIps.add(`${addressPort}#${remark}`);
            } else {
                otherNodes.push(line);
            }
        } else if (line.includes(':')) {
            allIps.add(line);
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
 * 处理 API 更新 (PUT /api/update)
 */
async function handleApiUpdate(request, env) {
    if (request.method !== 'PUT') {
        return new Response('Method Not Allowed', { status: 405 });
    }

    const url = new URL(request.url);
    const token = request.headers.get('Authorization') || url.searchParams.get('token');
    const mode = url.searchParams.get('mode'); // 'append' 或 overwrite

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

        let finalContent = content;
        if (mode === 'append') {
            const existing = await env.KV.get('ADD.txt') || '';
            finalContent = existing + (existing && !existing.endsWith('\n') ? '\n' : '') + content;
        } else {
            // 覆盖模式：记录原有优选 IP 到历史记录
            const existing = await env.KV.get('ADD.txt') || '';
            await saveHistoryRecord(env, existing);
        }
        await env.KV.put('ADD.txt', finalContent);
        await env.KV.put('UPDATE_TIME', new Date().toISOString());
        return new Response('Updated successfully (' + (mode === 'append' ? 'Appended' : 'Overwritten') + ')', { status: 200 });
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

    if (env.TOKEN && !isAuthByToken && !isAuthByCookie) {
        return new Response(JSON.stringify({ success: false, message: 'Unauthorized: Invalid token or login required' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json; charset=utf-8' }
        });
    }

    let history = [];
    if (env.KV) {
        try {
            const raw = await env.KV.get('HISTORY.json');
            if (raw) history = JSON.parse(raw);
        } catch (e) {
            history = [];
        }
    }

    return new Response(JSON.stringify({
        success: true,
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
async function saveHistoryRecord(env, oldContent) {
    if (!oldContent || !oldContent.trim()) return;

    const oldLines = splitLines(oldContent);
    if (oldLines.length === 0) return;

    // 1. 本次历史记录内部去重
    const uniqueNewIps = Array.from(new Set(oldLines));

    // 2. 读取现有历史记录
    let history = [];
    try {
        const raw = await env.KV.get('HISTORY.json');
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
    await env.KV.put('HISTORY.json', JSON.stringify(history));
}

/**
 * 处理后台管理
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

        if (isAuth && action === 'save') {
            const content = formData.get('content');
            const mode = formData.get('mode');

            if (env.KV) {
                const invalidLines = validateProxyList(content);
                if (invalidLines.length > 0) {
                    return new Response('格式错误:\n' + invalidLines.join('\n'), { status: 400 });
                }

                let finalContent = content;
                if (mode === 'append') {
                    const existing = await env.KV.get('ADD.txt') || '';
                    finalContent = existing + (existing && !existing.endsWith('\n') ? '\n' : '') + content;
                } else {
                    // 覆盖模式：保存旧优选 IP 到历史记录
                    const existing = await env.KV.get('ADD.txt') || '';
                    await saveHistoryRecord(env, existing);
                }
                await env.KV.put('ADD.txt', finalContent);
                await env.KV.put('UPDATE_TIME', new Date().toISOString());
                return new Response('Saved successfully', { status: 200 });
            }
        }
    }

    if (!isAuth) {
        return new Response(renderLoginPage(), { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }

    const currentIps = env.KV ? await env.KV.get('ADD.txt') || '' : 'KV not bound';
    const updateTime = env.KV ? await env.KV.get('UPDATE_TIME') || '' : '';
    let history = [];
    if (env.KV) {
        try {
            const raw = await env.KV.get('HISTORY.json');
            if (raw) history = JSON.parse(raw);
        } catch (e) {
            history = [];
        }
    }
    return new Response(renderAdminPage(currentIps, updateTime, history), { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

function splitLines(str) {
    return str.split(/\r?\n/).map(l => l.trim()).filter(l => l && !l.startsWith('//'));
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
            invalidLines.push(`"${line}" (缺少端口，需为 地址:端口 格式)`);
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
    <title>登录 - edgetunnel 优选 IP 管理后台</title>
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
        <h1>edgetunnel 管理后台</h1>
        <p class="subtitle">Cloudflare Worker 优选 IP 节点聚合管理服务</p>
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

function renderAdminPage(currentContent, updateTime, history = []) {
    let formattedTime = '暂无更新记录';
    if (updateTime) {
        try {
            const d = new Date(updateTime);
            formattedTime = new Intl.DateTimeFormat('zh-CN', {
                year: 'numeric',
                month: '2-digit',
                day: '2-digit',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                timeZone: 'Asia/Shanghai'
            }).format(d);
        } catch (e) {
            formattedTime = updateTime;
        }
    }

    const currentLines = splitLines(currentContent);
    const activeIpCount = currentLines.length;

    const historyItemsHtml = history.map((item, index) => {
        let itemTime = item.time;
        try {
            itemTime = new Intl.DateTimeFormat('zh-CN', {
                year: 'numeric',
                month: '2-digit',
                day: '2-digit',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                timeZone: 'Asia/Shanghai'
            }).format(new Date(item.time));
        } catch (e) {}

        const ipListText = (item.ips || []).join('\n');
        const ipCount = (item.ips || []).length;

        return `
        <div class="history-card">
            <div class="history-header">
                <div class="history-info">
                    <span class="history-tag">${index === 0 ? '最新备份' : `#${index + 1}`}</span>
                    <span class="history-time">
                        <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                        ${itemTime}
                    </span>
                    <span class="history-badge">${ipCount} 个 IP</span>
                </div>
                <div class="history-actions">
                    <button class="btn btn-xs btn-outline" onclick="copyHistoryText(\`${encodeURIComponent(ipListText)}\`)">
                        <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                        复制 IP
                    </button>
                    <button class="btn btn-xs btn-primary" onclick="restoreHistoryText(\`${encodeURIComponent(ipListText)}\`)">
                        <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/></svg>
                        导入至配置
                    </button>
                </div>
            </div>
            <pre class="history-code">${escapeHtml(ipListText)}</pre>
        </div>
        `;
    }).join('');

    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>管理后台 - edgetunnel 优选 IP</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: #6366f1;
            --primary-hover: #4f46e5;
            --primary-glow: rgba(99, 102, 241, 0.35);
            --success: #10b981;
            --success-glow: rgba(16, 185, 129, 0.3);
            --warning: #f59e0b;
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
                radial-gradient(circle at 90% 90%, rgba(192, 132, 252, 0.1), transparent 35%);
            min-height: 100vh;
            color: var(--text-main);
            padding: 2rem 1.5rem;
        }
        .container {
            max-width: 960px;
            margin: 0 auto;
        }

        /* Top Header Navigation */
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 2rem;
            flex-wrap: wrap;
            gap: 1rem;
        }
        .brand-section {
            display: flex;
            align-items: center;
            gap: 1rem;
        }
        .brand-logo {
            width: 44px;
            height: 44px;
            background: linear-gradient(135deg, #6366f1, #a855f7);
            border-radius: 0.85rem;
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 8px 16px -4px var(--primary-glow);
        }
        .brand-logo svg { width: 24px; height: 24px; fill: none; stroke: white; stroke-width: 2.2; }
        h1 {
            margin: 0;
            font-size: 1.4rem;
            font-weight: 800;
            background: linear-gradient(135deg, #a5b4fc, #c084fc, #38bdf8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            letter-spacing: -0.02em;
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
            width: 6px;
            height: 6px;
            background: #10b981;
            border-radius: 50%;
            box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
            70% { box-shadow: 0 0 0 6px rgba(16, 185, 129, 0); }
            100% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
        }

        /* Overview Stat Grid */
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
        .stat-card:hover {
            border-color: var(--border-hover);
            transform: translateY(-2px);
        }
        .stat-label { font-size: 0.8rem; font-weight: 500; color: var(--text-muted); margin-bottom: 0.25rem; }
        .stat-val { font-size: 1.35rem; font-weight: 800; color: white; font-family: 'Fira Code', monospace; }
        .stat-icon {
            width: 38px;
            height: 38px;
            border-radius: 0.75rem;
            background: rgba(255, 255, 255, 0.05);
            display: flex;
            align-items: center;
            justify-content: center;
            color: #818cf8;
        }
        .stat-icon svg { width: 20px; height: 20px; stroke-width: 2; }

        /* Main Card Container */
        .card {
            background: var(--card-bg);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid var(--border);
            padding: 2rem;
            border-radius: 1.75rem;
            box-shadow: 0 20px 40px -15px rgba(0, 0, 0, 0.5);
        }

        /* Tabs Styling */
        .tabs {
            display: flex;
            gap: 0.75rem;
            margin-bottom: 1.75rem;
            border-bottom: 1px solid var(--border);
            padding-bottom: 0.75rem;
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
        .tab-btn:hover {
            color: white;
            background: rgba(255, 255, 255, 0.05);
        }
        .tab-btn.active {
            color: white;
            background: linear-gradient(135deg, rgba(99, 102, 241, 0.25), rgba(168, 85, 247, 0.2));
            border-color: rgba(99, 102, 241, 0.4);
            box-shadow: 0 4px 12px rgba(99, 102, 241, 0.15);
        }

        /* Mode Selector Pills */
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
            user-select: none;
        }
        .mode-option.active {
            background: var(--primary);
            color: white;
            box-shadow: 0 4px 10px rgba(99, 102, 241, 0.3);
        }

        /* Textarea Editor */
        .editor-wrapper {
            position: relative;
        }
        textarea {
            width: 100%;
            height: 380px;
            background: var(--input-bg);
            border: 1px solid var(--border);
            border-radius: 1.25rem;
            color: #e2e8f0;
            padding: 1.25rem;
            font-family: 'Fira Code', monospace;
            font-size: 0.875rem;
            line-height: 1.6;
            resize: vertical;
            box-sizing: border-box;
            transition: all 0.25s ease;
        }
        textarea:focus {
            outline: none;
            border-color: var(--primary);
            box-shadow: 0 0 0 4px var(--primary-glow);
            background: rgba(15, 23, 42, 0.85);
        }
        textarea::-webkit-scrollbar { width: 8px; height: 8px; }
        textarea::-webkit-scrollbar-track { background: transparent; }
        textarea::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.15); border-radius: 4px; }
        textarea::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.3); }

        /* Action Toolbar */
        .actions {
            margin-top: 1.25rem;
            display: flex;
            gap: 1rem;
            justify-content: flex-end;
            align-items: center;
            flex-wrap: wrap;
        }
        .hint {
            color: var(--text-muted);
            font-size: 0.8rem;
            flex-grow: 1;
            display: flex;
            align-items: center;
            gap: 0.4rem;
        }
        .btn {
            padding: 0.75rem 1.6rem;
            border-radius: 0.85rem;
            border: none;
            font-size: 0.9rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.25s ease;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .btn-xs {
            padding: 0.35rem 0.75rem;
            font-size: 0.775rem;
            border-radius: 0.6rem;
            font-weight: 600;
        }
        .btn-primary {
            background: linear-gradient(135deg, #6366f1, #4f46e5);
            color: white;
            box-shadow: 0 8px 16px -4px rgba(99, 102, 241, 0.4);
        }
        .btn-primary:hover {
            background: linear-gradient(135deg, #4f46e5, #4338ca);
            transform: translateY(-2px);
            box-shadow: 0 12px 20px -4px rgba(99, 102, 241, 0.6);
        }
        .btn-outline {
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid var(--border);
            color: #cbd5e1;
        }
        .btn-outline:hover {
            background: rgba(255, 255, 255, 0.1);
            border-color: var(--border-hover);
            color: white;
        }

        /* Toast Feedback */
        #toast {
            position: fixed;
            bottom: 2rem;
            right: 2rem;
            padding: 0.9rem 1.75rem;
            border-radius: 1rem;
            background: var(--success);
            color: white;
            font-weight: 600;
            font-size: 0.9rem;
            box-shadow: 0 10px 25px -3px var(--success-glow);
            transform: translateY(100px);
            transition: all 0.4s cubic-bezier(0.175, 0.885, 0.32, 1.275);
            opacity: 0;
            z-index: 1000;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        #toast.show { transform: translateY(0); opacity: 1; }

        /* History Cards */
        .history-container {
            display: flex;
            flex-direction: column;
            gap: 1.25rem;
        }
        .history-card {
            background: var(--input-bg);
            border: 1px solid var(--border);
            border-radius: 1.25rem;
            padding: 1.1rem 1.4rem;
            transition: all 0.25s ease;
        }
        .history-card:hover {
            border-color: var(--border-hover);
            transform: translateY(-2px);
            box-shadow: 0 10px 20px -5px rgba(0, 0, 0, 0.3);
        }
        .history-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.85rem;
            flex-wrap: wrap;
            gap: 0.75rem;
        }
        .history-info {
            display: flex;
            align-items: center;
            gap: 0.6rem;
        }
        .history-tag {
            background: rgba(99, 102, 241, 0.18);
            color: #a5b4fc;
            border: 1px solid rgba(99, 102, 241, 0.3);
            font-weight: 700;
            padding: 0.15rem 0.55rem;
            border-radius: 0.5rem;
            font-size: 0.75rem;
        }
        .history-time {
            color: var(--text-muted);
            font-size: 0.825rem;
            display: flex;
            align-items: center;
            gap: 0.35rem;
        }
        .history-badge {
            background: rgba(16, 185, 129, 0.15);
            color: #34d399;
            border: 1px solid rgba(16, 185, 129, 0.25);
            font-size: 0.75rem;
            padding: 0.15rem 0.55rem;
            border-radius: 0.5rem;
            font-weight: 600;
        }
        .history-actions {
            display: flex;
            gap: 0.5rem;
        }
        .history-code {
            margin: 0;
            background: rgba(0, 0, 0, 0.4);
            border-radius: 0.75rem;
            padding: 0.85rem 1.1rem;
            font-family: 'Fira Code', monospace;
            font-size: 0.825rem;
            color: #6ee7b7;
            max-height: 160px;
            overflow-y: auto;
            white-space: pre-wrap;
            word-break: break-all;
            line-height: 1.5;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }
        .empty-history {
            text-align: center;
            padding: 3.5rem 1rem;
            color: var(--text-muted);
        }
        .api-note {
            margin-top: 1.25rem;
            padding: 0.85rem 1.2rem;
            background: rgba(99, 102, 241, 0.08);
            border-radius: 1rem;
            border: 1px solid rgba(99, 102, 241, 0.2);
            font-size: 0.825rem;
            color: #a5b4fc;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- Top Header Navigation -->
        <header>
            <div class="brand-section">
                <div class="brand-logo">
                    <svg viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
                </div>
                <div>
                    <h1>edgetunnel 优选 IP 管理</h1>
                    <div class="status-pill">
                        <span class="pulse-dot"></span>
                        <span>服务正常运行中</span>
                    </div>
                </div>
            </div>
            <button class="btn btn-outline" onclick="location.href='/login'">
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/></svg>
                退出登录
            </button>
        </header>

        <!-- Overview Stat Grid -->
        <div class="stats-grid">
            <div class="stat-card">
                <div>
                    <div class="stat-label">生效优选 IP</div>
                    <div class="stat-val" id="activeCountVal">${activeIpCount}</div>
                </div>
                <div class="stat-icon">
                    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"/></svg>
                </div>
            </div>
            <div class="stat-card">
                <div>
                    <div class="stat-label">最近更新时间</div>
                    <div class="stat-val" style="font-size: 0.95rem; font-family: 'Inter', sans-serif;">${formattedTime}</div>
                </div>
                <div class="stat-icon" style="color: #c084fc;">
                    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                </div>
            </div>
            <div class="stat-card">
                <div>
                    <div class="stat-label">历史备份版本</div>
                    <div class="stat-val" style="color: #38bdf8;">${history.length} <span style="font-size: 0.85rem; font-weight: normal; color: var(--text-muted);">/ 5 份</span></div>
                </div>
                <div class="stat-icon" style="color: #38bdf8;">
                    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 8h14M5 8a2 2 0 110-4h14a2 2 0 110 4M5 8v10a2 2 0 002 2h10a2 2 0 002-2V8m-9 4h4"/></svg>
                </div>
            </div>
        </div>

        <!-- Main Workspace Card -->
        <div class="card">
            <div class="tabs">
                <button class="tab-btn active" id="tabIps" onclick="switchTab('ips')">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>
                    优选 IP 配置
                </button>
                <button class="tab-btn" id="tabHistory" onclick="switchTab('history')">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                    历史 IP 记录 (${history.length})
                </button>
            </div>
            
            <!-- 优选 IP 配置 TAB -->
            <div id="panelIps">
                <div class="label-group">
                    <span class="label">
                        <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                        自定义优选 IP 列表 (格式: 地址:端口#备注)
                    </span>
                    <div class="mode-selector" id="modeSelector">
                        <div class="mode-option active" data-mode="overwrite" onclick="setMode('overwrite')">覆盖模式</div>
                        <div class="mode-option" data-mode="append" onclick="setMode('append')">追加模式</div>
                    </div>
                </div>
                <div class="editor-wrapper">
                    <textarea id="content" placeholder="例如: 1.1.1.1:443#Cloudflare" oninput="updateCounter()">${escapeHtml(currentContent)}</textarea>
                </div>
                <div class="actions">
                    <div class="hint" id="modeHint">
                        <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                        当前模式：用输入的内容覆盖现有优选 IP 列表（旧记录自动存入历史）
                    </div>
                    <button class="btn btn-outline" onclick="copyCurrentContent()">
                        <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                        复制全部
                    </button>
                    <button class="btn btn-primary" id="saveBtn" onclick="save()">
                        <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7H5a2 2 0 00-2 2v9a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-3m-1 4l-3 3m0 0l-3-3m3 3V4"/></svg>
                        保存更改
                    </button>
                </div>
            </div>

            <!-- 历史 IP 记录 TAB -->
            <div id="panelHistory" style="display: none;">
                <div class="history-container">
                    ${history.length > 0 ? historyItemsHtml : `
                    <div class="empty-history">
                        <svg width="54" height="54" fill="none" stroke="currentColor" viewBox="0 0 24 24" style="opacity:0.3; margin-bottom: 1rem; stroke-width: 1.5;"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                        <div style="font-weight: 600; font-size: 1rem; margin-bottom: 0.3rem;">暂无历史 IP 备份</div>
                        <div style="font-size: 0.85rem;">使用覆盖模式保存优选 IP 时，旧记录会自动备份至此处（支持全历史去重，最多 5 份）</div>
                    </div>`}
                </div>
                <div class="api-note">
                    <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24" style="flex-shrink:0;"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                    <span><strong>API 查询说明:</strong> 支持通过 HTTP GET 接口 <code>/api/history?token=YOUR_TOKEN</code> 获取 JSON 格式的历史优选 IP 记录。</span>
                </div>
            </div>
        </div>
    </div>
    <div id="toast">
        <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5 13l4 4L19 7"/></svg>
        <span id="toastMsg">保存成功！</span>
    </div>

    <script>
        let activeTab = 'ips';
        let currentMode = 'overwrite';
        const initialIpsContent = document.getElementById('content').value;

        function switchTab(tab) {
            activeTab = tab;
            document.getElementById('tabIps').classList.toggle('active', tab === 'ips');
            document.getElementById('tabHistory').classList.toggle('active', tab === 'history');

            const panelIps = document.getElementById('panelIps');
            const panelHistory = document.getElementById('panelHistory');

            if (tab === 'ips') {
                panelIps.style.display = 'block';
                panelHistory.style.display = 'none';
            } else {
                panelIps.style.display = 'none';
                panelHistory.style.display = 'block';
            }
        }

        function setMode(mode) {
            currentMode = mode;
            document.querySelectorAll('.mode-option').forEach(opt => {
                opt.classList.toggle('active', opt.dataset.mode === mode);
            });
            
            const hint = document.getElementById('modeHint');
            const textarea = document.getElementById('content');
            
            if (mode === 'append') {
                hint.innerHTML = '<svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 6v6m0 0v6m0-6h6m-6 0H6"/></svg>当前模式：将输入的内容追加到现有优选 IP 列表末尾';
                textarea.placeholder = '输入要追加的 IP 列表...';
                if (textarea.value.trim() === initialIpsContent.trim()) {
                    textarea.value = '';
                }
            } else {
                hint.innerHTML = '<svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>当前模式：用输入的内容覆盖现有优选 IP 列表（旧记录自动存入历史）';
                textarea.placeholder = '例如: 1.1.1.1:443#Cloudflare';
                if (textarea.value.trim() === '') {
                    textarea.value = initialIpsContent;
                }
            }
            updateCounter();
        }

        function updateCounter() {
            const val = document.getElementById('content').value;
            const lines = val.split(/\\r?\\n/).map(l => l.trim()).filter(l => l && !l.startsWith('//') && l.includes(':'));
            document.getElementById('activeCountVal').innerText = lines.length;
        }

        function copyCurrentContent() {
            const val = document.getElementById('content').value;
            if (!val.trim()) {
                showToast('编辑器内容为空！', true);
                return;
            }
            navigator.clipboard.writeText(val).then(() => {
                showToast('已复制当前列表到剪贴板！');
            }).catch(err => {
                showToast('复制失败: ' + err, true);
            });
        }

        async function save() {
            const textarea = document.getElementById('content');
            const content = textarea.value;
            const btn = document.getElementById('saveBtn');
            btn.disabled = true;
            const originalHtml = btn.innerHTML;
            btn.innerHTML = '正在保存...';

            try {
                const formData = new FormData();
                formData.append('action', 'save');
                formData.append('content', content);
                formData.append('mode', currentMode);

                const res = await fetch('/admin', {
                    method: 'POST',
                    body: formData
                });

                if (res.ok) {
                    showToast(currentMode === 'append' ? '追加成功！' : '保存成功 (旧记录已自动备份至历史)！');
                    localStorage.setItem('adminActiveTab', activeTab);
                    setTimeout(() => location.reload(), 1000);
                } else {
                    const errorMsg = await res.text();
                    showToast(errorMsg, true);
                }
            } catch (e) {
                showToast('保存出错: ' + e.message, true);
            } finally {
                btn.disabled = false;
                btn.innerHTML = originalHtml;
            }
        }

        function copyHistoryText(encodedText) {
            const text = decodeURIComponent(encodedText);
            navigator.clipboard.writeText(text).then(() => {
                showToast('已复制该历史 IP 列表到剪贴板！');
            }).catch(err => {
                showToast('复制失败: ' + err, true);
            });
        }

        function restoreHistoryText(encodedText) {
            const text = decodeURIComponent(encodedText);
            switchTab('ips');
            setMode('overwrite');
            document.getElementById('content').value = text;
            updateCounter();
            showToast('已将历史 IP 导入至编辑器，确认无误后点击“保存更改”生效！');
        }

        window.addEventListener('DOMContentLoaded', () => {
            const savedTab = localStorage.getItem('adminActiveTab') || 'ips';
            switchTab(savedTab);
            localStorage.removeItem('adminActiveTab');
            updateCounter();
        });

        function showToast(msg, isError = false) {
            const toast = document.getElementById('toast');
            document.getElementById('toastMsg').innerText = msg;
            toast.style.background = isError ? 'var(--danger)' : 'var(--success)';
            toast.style.boxShadow = isError ? '0 10px 25px -3px rgba(239, 68, 68, 0.4)' : '0 10px 25px -3px var(--success-glow)';
            toast.classList.add('show');
            setTimeout(() => toast.classList.remove('show'), 4000);
        }
    </script>
</body>
</html>`;
}
