#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Web UI template generator for Clash & Sing-box Subscription Manager.
Provides responsive, modern Glassmorphism HTML/CSS/JS frontend.
"""

def get_login_page_html(error_msg: str = "") -> str:
    """Return standalone HTML for the login page."""
    error_html = f'<div class="alert alert-error">{error_msg}</div>' if error_msg else ''
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>登录 - Sing-box & Clash 订阅同步管理器</title>
    <style>
        :root {{
            --bg-grad: linear-gradient(135deg, #0f172a 0%, #1e1b4b 50%, #0f172a 100%);
            --card-bg: rgba(30, 41, 59, 0.75);
            --card-border: rgba(255, 255, 255, 0.12);
            --primary: #6366f1;
            --primary-hover: #4f46e5;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            background: var(--bg-grad);
            color: var(--text-main);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }}
        .login-card {{
            background: var(--card-bg);
            backdrop-filter: blur(16px);
            -webkit-backdrop-filter: blur(16px);
            border: 1px solid var(--card-border);
            border-radius: 18px;
            padding: 40px;
            width: 100%;
            max-width: 420px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
            text-align: center;
        }}
        .logo-icon {{
            font-size: 48px;
            margin-bottom: 16px;
            display: inline-block;
        }}
        h1 {{
            font-size: 22px;
            font-weight: 700;
            margin-bottom: 8px;
            letter-spacing: -0.5px;
        }}
        .subtitle {{
            font-size: 13px;
            color: var(--text-muted);
            margin-bottom: 28px;
        }}
        .form-group {{
            margin-bottom: 20px;
            text-align: left;
        }}
        label {{
            display: block;
            font-size: 13px;
            font-weight: 500;
            color: var(--text-muted);
            margin-bottom: 6px;
        }}
        input[type="text"], input[type="password"] {{
            width: 100%;
            padding: 12px 14px;
            background: rgba(15, 23, 42, 0.6);
            border: 1px solid var(--card-border);
            border-radius: 10px;
            color: #fff;
            font-size: 14px;
            transition: all 0.2s;
        }}
        input:focus {{
            outline: none;
            border-color: var(--primary);
            box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.3);
        }}
        .btn {{
            width: 100%;
            padding: 12px;
            background: var(--primary);
            color: white;
            border: none;
            border-radius: 10px;
            font-size: 15px;
            font-weight: 600;
            cursor: pointer;
            transition: background 0.2s;
            margin-top: 10px;
        }}
        .btn:hover {{ background: var(--primary-hover); }}
        .alert-error {{
            background: rgba(239, 68, 68, 0.15);
            border: 1px solid rgba(239, 68, 68, 0.3);
            color: #fca5a5;
            padding: 10px 14px;
            border-radius: 8px;
            font-size: 13px;
            margin-bottom: 20px;
            text-align: left;
        }}
        .footer {{
            margin-top: 24px;
            font-size: 12px;
            color: var(--text-muted);
        }}
    </style>
</head>
<body>
    <div class="login-card">
        <div class="logo-icon">⚡</div>
        <h1>Sing-box & Clash</h1>
        <p class="subtitle">订阅注入与管理系统</p>
        {error_html}
        <form method="POST" action="/login">
            <div class="form-group">
                <label for="username">管理账号</label>
                <input type="text" id="username" name="username" placeholder="请输入用户名" required autofocus>
            </div>
            <div class="form-group">
                <label for="password">管理密码</label>
                <input type="password" id="password" name="password" placeholder="请输入密码" required>
            </div>
            <button type="submit" class="btn">登 录</button>
        </form>
        <div class="footer">
            默认账号: admin / admin1234
        </div>
    </div>
</body>
</html>
"""


def get_dashboard_html() -> str:
    """Return main dashboard single-page web app."""
    return """<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Sing-box & Clash 订阅同步管理器</title>
    <style>
        :root {
            --bg-color: #0b0f19;
            --card-bg: rgba(18, 24, 39, 0.85);
            --card-border: rgba(255, 255, 255, 0.08);
            --card-hover-border: rgba(99, 102, 241, 0.4);
            --primary: #6366f1;
            --primary-light: #818cf8;
            --primary-hover: #4f46e5;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --text-main: #f3f4f6;
            --text-muted: #9ca3af;
            --input-bg: rgba(11, 15, 25, 0.7);
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            background-color: var(--bg-color);
            background-image: 
                radial-gradient(at 0% 0%, rgba(99, 102, 241, 0.15) 0px, transparent 50%),
                radial-gradient(at 100% 100%, rgba(139, 92, 246, 0.12) 0px, transparent 50%);
            color: var(--text-main);
            min-height: 100vh;
            padding-bottom: 60px;
        }
        .navbar {
            background: rgba(18, 24, 39, 0.9);
            backdrop-filter: blur(12px);
            border-bottom: 1px solid var(--card-border);
            padding: 14px 24px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            position: sticky;
            top: 0;
            z-index: 100;
        }
        .nav-brand {
            display: flex;
            align-items: center;
            gap: 10px;
            font-size: 18px;
            font-weight: 700;
        }
        .nav-brand span { color: var(--primary-light); }
        .nav-actions {
            display: flex;
            align-items: center;
            gap: 12px;
        }
        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 4px 10px;
            background: rgba(16, 185, 129, 0.15);
            border: 1px solid rgba(16, 185, 129, 0.3);
            color: #34d399;
            border-radius: 9999px;
            font-size: 12px;
            font-weight: 500;
        }
        .status-dot {
            width: 8px;
            height: 8px;
            background: #10b981;
            border-radius: 50%;
            box-shadow: 0 0 8px #10b981;
        }
        .container {
            max-width: 1200px;
            margin: 28px auto;
            padding: 0 20px;
            display: grid;
            grid-template-columns: 1fr;
            gap: 24px;
        }
        @media (min-width: 992px) {
            .grid-2 {
                display: grid;
                grid-template-columns: 1.1fr 0.9fr;
                gap: 24px;
            }
        }
        .card {
            background: var(--card-bg);
            backdrop-filter: blur(12px);
            border: 1px solid var(--card-border);
            border-radius: 16px;
            padding: 24px;
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
            transition: border-color 0.2s;
        }
        .card:hover {
            border-color: var(--card-hover-border);
        }
        .card-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 20px;
            padding-bottom: 12px;
            border-bottom: 1px solid var(--card-border);
        }
        .card-title {
            font-size: 16px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .btn {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 6px;
            padding: 8px 14px;
            border-radius: 8px;
            font-size: 13px;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.2s;
            border: 1px solid transparent;
            text-decoration: none;
        }
        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
        .btn-primary { background: var(--primary); color: #fff; }
        .btn-primary:hover:not(:disabled) { background: var(--primary-hover); }
        .btn-secondary {
            background: rgba(255, 255, 255, 0.06);
            border-color: var(--card-border);
            color: var(--text-main);
        }
        .btn-secondary:hover:not(:disabled) { background: rgba(255, 255, 255, 0.12); }
        .btn-success { background: #059669; color: #fff; }
        .btn-success:hover:not(:disabled) { background: #047857; }
        .btn-danger { background: rgba(239, 68, 68, 0.2); border-color: rgba(239, 68, 68, 0.4); color: #f87171; }
        .btn-danger:hover:not(:disabled) { background: rgba(239, 68, 68, 0.3); }
        .btn-sm { padding: 5px 10px; font-size: 12px; }

        /* Subscription Box */
        .sub-box {
            background: var(--input-bg);
            border: 1px dashed var(--primary);
            border-radius: 12px;
            padding: 16px;
            margin-bottom: 18px;
        }
        .sub-url-row {
            display: flex;
            align-items: center;
            gap: 10px;
            margin-top: 8px;
        }
        .sub-url-input {
            flex: 1;
            background: rgba(0, 0, 0, 0.4);
            border: 1px solid var(--card-border);
            border-radius: 8px;
            padding: 10px 12px;
            color: #38bdf8;
            font-family: monospace;
            font-size: 13px;
            word-break: break-all;
        }
        .uuid-badge {
            font-family: monospace;
            background: rgba(99, 102, 241, 0.15);
            padding: 2px 8px;
            border-radius: 4px;
            color: var(--primary-light);
            font-size: 13px;
        }

        /* QR Container */
        .qr-section {
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            background: rgba(11, 15, 25, 0.5);
            border-radius: 12px;
            padding: 20px;
            border: 1px solid var(--card-border);
            text-align: center;
        }
        .qr-wrapper {
            background: #ffffff;
            padding: 12px;
            border-radius: 10px;
            display: inline-block;
            box-shadow: 0 4px 14px rgba(0, 0, 0, 0.4);
            margin-bottom: 12px;
            min-width: 180px;
            min-height: 180px;
        }
        .qr-wrapper svg {
            display: block;
            width: 180px;
            height: 180px;
        }
        .qr-tip {
            font-size: 12px;
            color: var(--text-muted);
        }

        /* Form */
        .form-grid {
            display: grid;
            grid-template-columns: 1fr;
            gap: 16px;
        }
        @media (min-width: 600px) {
            .form-grid-2 {
                grid-template-columns: 1fr 1fr;
            }
        }
        .form-group {
            display: flex;
            flex-direction: column;
            gap: 6px;
        }
        label {
            font-size: 13px;
            font-weight: 500;
            color: var(--text-muted);
        }
        input, select, textarea {
            background: var(--input-bg);
            border: 1px solid var(--card-border);
            border-radius: 8px;
            padding: 10px 12px;
            color: #fff;
            font-size: 13px;
            transition: border-color 0.2s;
        }
        input:focus, select:focus, textarea:focus {
            outline: none;
            border-color: var(--primary);
            box-shadow: 0 0 0 2px rgba(99, 102, 241, 0.25);
        }
        .input-group {
            display: flex;
            gap: 8px;
        }
        .input-group input { flex: 1; }

        /* Preview area */
        .preview-box {
            background: #060911;
            border: 1px solid var(--card-border);
            border-radius: 8px;
            padding: 14px;
            font-family: monospace;
            font-size: 12px;
            color: #cbd5e1;
            max-height: 280px;
            overflow-y: auto;
            white-space: pre-wrap;
            word-break: break-all;
        }
        .tag-pill {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 500;
            margin: 2px;
        }
        .tag-node { background: rgba(56, 189, 248, 0.15); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.3); }
        .tag-del { background: rgba(239, 68, 68, 0.15); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.3); }
        .tag-keep { background: rgba(16, 185, 129, 0.15); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }

        /* Toast notification */
        #toast {
            position: fixed;
            bottom: 24px;
            right: 24px;
            background: rgba(30, 41, 59, 0.95);
            border: 1px solid var(--card-border);
            color: #fff;
            padding: 12px 20px;
            border-radius: 10px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.5);
            font-size: 14px;
            z-index: 1000;
            display: none;
            align-items: center;
            gap: 10px;
        }
    </style>
</head>
<body>
    <nav class="navbar">
        <div class="nav-brand">
            <span>⚡</span> Clash & Sing-box 订阅同步服务
        </div>
        <div class="nav-actions">
            <div class="status-badge">
                <div class="status-dot"></div>
                <span id="service-status">运行中 (Port: <span id="lbl-port">8000</span>)</span>
            </div>
            <a href="/logout" class="btn btn-secondary btn-sm" onclick="event.preventDefault(); logout();">退出</a>
        </div>
    </nav>

    <div class="container">
        <!-- Top Full Width Card: Subscription URL & QR Code -->
        <div class="card">
            <div class="card-header">
                <div class="card-title">
                    <span>🔗</span> 订阅连接与二维码
                </div>
                <div style="display: flex; gap: 8px;">
                    <button class="btn btn-secondary btn-sm" onclick="regenerateUUID()">
                        <span>🎲</span> 更换随机 UUID
                    </button>
                    <button class="btn btn-success btn-sm" onclick="downloadYaml()">
                        <span>📥</span> 下载 YAML 配置
                    </button>
                </div>
            </div>

            <div class="grid-2">
                <div>
                    <div class="sub-box">
                        <div style="display: flex; justify-content: space-between; align-items: center;">
                            <label style="color: var(--primary-light); font-weight: 600;">Clash 客户端订阅地址 (带 Token)</label>
                            <span class="uuid-badge" id="lbl-uuid">加载中...</span>
                        </div>
                        <div class="sub-url-row">
                            <input type="text" id="sub-url-display" class="sub-url-input" readonly value="正在生成订阅地址...">
                            <button class="btn btn-primary" onclick="copySubUrl()">📋 复制</button>
                            <button class="btn btn-secondary" onclick="importToClash()">🚀 导入 Clash</button>
                        </div>
                    </div>

                    <div style="font-size: 13px; color: var(--text-muted); line-height: 1.6;">
                        <p>💡 <b>使用说明：</b></p>
                        <p>1. 复制上方订阅地址，直接粘贴到 <b>Clash Verge / Clash Meta / Clash for Windows / Flclash</b> 等客户端。</p>
                        <p>2. 点击「更换随机 UUID」可随时撤销旧订阅并生成新的防撞链接，配置即刻生效无需重启。</p>
                        <p>3. 提取当前服务器上的 Sing-box 节点并自动注入「节点选择」分组（SOCKS 协议节点自动置于末尾），自动清理失效地域组。</p>
                    </div>
                </div>

                <div class="qr-section">
                    <div class="qr-wrapper" id="qr-container">
                        <div style="width: 180px; height: 180px; display: flex; align-items: center; justify-content: center; color: #64748b; font-size: 12px;">
                            二维码生成中...
                        </div>
                    </div>
                    <div class="qr-tip">📱 手机客户端扫描上方二维码直接导入订阅</div>
                </div>
            </div>
        </div>

        <!-- Middle 2-Column Grid: Config Management & Sync Test -->
        <div class="grid-2">
            <!-- Left: Configuration Form -->
            <div class="card">
                <div class="card-header">
                    <div class="card-title">
                        <span>⚙️</span> 服务参数设置
                    </div>
                    <button class="btn btn-primary btn-sm" id="btn-save" onclick="saveConfig()">💾 保存配置</button>
                </div>

                <form id="cfg-form" onsubmit="event.preventDefault(); saveConfig();" class="form-grid">
                    <div class="form-group">
                        <label for="clash_sub_url">Clash 原始上游订阅链接 (留空则使用内置规则模板)</label>
                        <div class="input-group">
                            <input type="text" id="clash_sub_url" placeholder="https://example.com/api/v1/client/subscribe?token=...">
                            <button type="button" class="btn btn-secondary btn-sm" id="btn-fetch-test" onclick="testFetchSub()">测试拉取</button>
                        </div>
                    </div>

                    <div class="form-grid form-grid-2">
                        <div class="form-group">
                            <label for="upstream_proxy">上游拉取本地代理 (优先使用，不可用时回落直连)</label>
                            <input type="text" id="upstream_proxy" value="socks5h://127.0.0.1:2080" placeholder="socks5h://127.0.0.1:2080">
                        </div>
                        <div class="form-group">
                            <label for="node_ip">节点公网 IP (用于注入节点的 IP 字段)</label>
                            <div class="input-group">
                                <input type="text" id="node_ip" placeholder="例如 8.137.160.254 (留空自动探测)">
                                <button type="button" class="btn btn-secondary btn-sm" onclick="detectIP()">探测 IP</button>
                            </div>
                        </div>
                    </div>

                    <div class="form-grid form-grid-2">
                        <div class="form-group">
                            <label for="singbox_config_path">Sing-box 配置文件路径</label>
                            <input type="text" id="singbox_config_path" value="/etc/sing-box/config.json">
                        </div>
                        <div class="form-group">
                            <label for="target_group_pattern">注入目标分组名称包含关键词</label>
                            <input type="text" id="target_group_pattern" value="节点选择">
                        </div>
                    </div>

                    <div class="form-grid form-grid-2">
                        <div class="form-group">
                            <label for="exclude_patterns">需删除清理的分组 (逗号分隔)</label>
                            <input type="text" id="exclude_patterns" value="自动选择, 节点">
                        </div>
                        <div class="form-group">
                            <label for="server_port">Web 监听端口 (修改需重启生效)</label>
                            <input type="number" id="server_port" value="8000" min="1" max="65535">
                        </div>
                    </div>

                    <div class="form-grid form-grid-2">
                        <div class="form-group">
                            <label for="auth_user">管理用户名</label>
                            <input type="text" id="auth_user" value="admin">
                        </div>
                        <div class="form-group">
                            <label for="auth_pass">管理密码 (留空则不修改)</label>
                            <input type="password" id="auth_pass" placeholder="输入新密码">
                        </div>
                    </div>
                </form>
            </div>

            <!-- Right: Sing-box Extracted Nodes & Rule Status -->
            <div class="card">
                <div class="card-header">
                    <div class="card-title">
                        <span>🔍</span> 节点提取与实时同步测试
                    </div>
                    <button class="btn btn-secondary btn-sm" id="btn-sync-test" onclick="runSyncTest()">🔄 立即测试转换</button>
                </div>

                <div style="margin-bottom: 14px;">
                    <label style="margin-bottom: 6px; display: block;">Sing-box 提取到的代理节点 (<span id="node-count">0</span> 个):</label>
                    <div id="nodes-preview-tags" style="margin-bottom: 8px;">
                        <span style="color:var(--text-muted);font-size:12px;">加载中...</span>
                    </div>
                </div>

                <div style="margin-bottom: 14px;">
                    <label style="margin-bottom: 6px; display: block;">分组清理与保留统计:</label>
                    <div style="font-size: 12px; color: var(--text-muted); margin-bottom: 4px;">
                        🗑️ 已清理组 (<span id="del-group-count">0</span>): <span id="del-groups-tags">-</span>
                    </div>
                    <div style="font-size: 12px; color: var(--text-muted);">
                        ✅ 已保留组 (<span id="keep-group-count">0</span>): <span id="keep-groups-tags">-</span>
                    </div>
                </div>

                <div>
                    <label style="margin-bottom: 6px; display: block;">转换后 Clash YAML 片段预览:</label>
                    <div id="yaml-preview" class="preview-box">点击上方「🔄 立即测试转换」可拉取上游规则并生成转换后的 Clash 完整配置预览。</div>
                </div>
            </div>
        </div>
    </div>

    <div id="toast"></div>

    <script>
        let currentConfig = {};
        let currentStatus = {};

        function showToast(msg, duration = 3000) {
            const t = document.getElementById('toast');
            if (t) {
                t.innerText = msg;
                t.style.display = 'flex';
                setTimeout(() => { t.style.display = 'none'; }, duration);
            }
        }

        async function fetchStatus() {
            try {
                const res = await fetch('/api/status');
                if (res.status === 401) {
                    window.location.href = '/login';
                    return;
                }
                const data = await res.json();
                currentStatus = data;
                currentConfig = data.config;

                // 1. Immediately update Subscription URL & Badges
                const origin = window.location.origin;
                const fullSubUrl = `${origin}/sub/${data.uuid}`;
                document.getElementById('sub-url-display').value = fullSubUrl;
                document.getElementById('lbl-uuid').innerText = data.uuid;
                document.getElementById('lbl-port').innerText = data.server_port;

                // 2. Immediately render QR Code
                renderQRCode(fullSubUrl);

                // 3. Immediately populate Form Inputs
                document.getElementById('clash_sub_url').value = currentConfig.subscription?.clash_sub_url || '';
                document.getElementById('upstream_proxy').value = currentConfig.subscription?.upstream_proxy || 'socks5h://127.0.0.1:2080';
                document.getElementById('node_ip').value = currentConfig.singbox?.node_ip || '';
                document.getElementById('singbox_config_path').value = currentConfig.singbox?.config_path || '/etc/sing-box/config.json';
                document.getElementById('target_group_pattern').value = currentConfig.filter?.target_group_pattern || '节点选择';
                document.getElementById('exclude_patterns').value = (currentConfig.filter?.exclude_group_patterns || ['自动选择', '节点']).join(', ');
                document.getElementById('auth_user').value = currentConfig.auth?.username || 'admin';
                document.getElementById('server_port').value = currentConfig.server?.port || 8000;

                // 4. Update Sing-box local nodes preview tags immediately
                const sbNodes = data.singbox_status?.nodes || [];
                document.getElementById('node-count').innerText = sbNodes.length;
                const nodesContainer = document.getElementById('nodes-preview-tags');
                if (sbNodes.length > 0) {
                    nodesContainer.innerHTML = sbNodes.map(n => 
                        `<span class="tag-pill tag-node">${n.name} (${n.type}:${n.port})</span>`
                    ).join(' ');
                } else {
                    nodesContainer.innerHTML = '<span style="color:var(--text-muted);font-size:12px;">未在 Sing-box 探测到有效入站代理</span>';
                }
            } catch (err) {
                console.error("Status fetch failed:", err);
            }
        }

        async function renderQRCode(text) {
            try {
                const res = await fetch(`/api/qrcode?text=${encodeURIComponent(text)}`);
                if (res.ok) {
                    const svgText = await res.text();
                    document.getElementById('qr-container').innerHTML = svgText;
                }
            } catch (err) {
                console.error("QR render error:", err);
            }
        }

        async function copySubUrl() {
            const urlInput = document.getElementById('sub-url-display');
            urlInput.select();
            urlInput.setSelectionRange(0, 99999);
            try {
                await navigator.clipboard.writeText(urlInput.value);
                showToast('✅ 订阅地址已成功复制到剪贴板！');
            } catch (err) {
                document.execCommand('copy');
                showToast('✅ 订阅地址已复制！');
            }
        }

        function importToClash() {
            const url = document.getElementById('sub-url-display').value;
            const clashScheme = `clash://install-config?url=${encodeURIComponent(url)}&name=${encodeURIComponent('Singbox-Clash')}`;
            window.location.href = clashScheme;
            showToast('🚀 已尝试调用 Clash 客户端一键导入');
        }

        function downloadYaml() {
            const url = document.getElementById('sub-url-display').value;
            window.open(url, '_blank');
        }

        async function regenerateUUID() {
            if (!confirm('⚠️ 确定要更换随机 UUID 吗？\\n更换后原订阅地址将立即失效，需要在客户端重新导入。')) {
                return;
            }
            try {
                const res = await fetch('/api/regenerate-uuid', { method: 'POST' });
                const data = await res.json();
                if (data.success) {
                    showToast('🎲 随机 UUID 更换成功！');
                    await fetchStatus();
                } else {
                    alert('更换失败: ' + (data.error || '未知错误'));
                }
            } catch (err) {
                alert('请求异常: ' + err.message);
            }
        }

        async function detectIP() {
            try {
                showToast('🔍 正在探测公网 IP...');
                const res = await fetch('/api/detect-ip');
                const data = await res.json();
                if (data.ip) {
                    document.getElementById('node_ip').value = data.ip;
                    showToast(`✅ 探测成功: ${data.ip}`);
                }
            } catch (err) {
                showToast('❌ 探测失败');
            }
        }

        async function testFetchSub() {
            const subUrl = document.getElementById('clash_sub_url').value.trim();
            const proxy = document.getElementById('upstream_proxy').value.trim();
            if (!subUrl) {
                alert('请先输入 Clash 原始订阅链接');
                return;
            }
            const btn = document.getElementById('btn-fetch-test');
            btn.disabled = true;
            btn.innerText = '⏳ 拉取中...';
            showToast('🌐 正在拉取订阅配置 (优先代理 -> 直连回落)...');
            try {
                const res = await fetch('/api/test-fetch', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ url: subUrl, proxy: proxy })
                });
                const data = await res.json();
                if (data.success) {
                    alert(`✅ 成功拉取订阅！\\n• 文件大小: ${data.size_str}\\n• 包含节点数: ${data.proxies_count} 个\\n• 使用代理: ${data.proxy_used || '直连'}`);
                } else {
                    alert('❌ 拉取失败: ' + data.error);
                }
            } catch (err) {
                alert('请求异常: ' + err.message);
            } finally {
                btn.disabled = false;
                btn.innerText = '测试拉取';
            }
        }

        async function saveConfig() {
            const excludeArr = document.getElementById('exclude_patterns').value
                .split(',')
                .map(s => s.trim())
                .filter(s => s.length > 0);

            const payload = {
                clash_sub_url: document.getElementById('clash_sub_url').value.trim(),
                upstream_proxy: document.getElementById('upstream_proxy').value.trim(),
                node_ip: document.getElementById('node_ip').value.trim(),
                singbox_config_path: document.getElementById('singbox_config_path').value.trim(),
                target_group_pattern: document.getElementById('target_group_pattern').value.trim(),
                exclude_group_patterns: excludeArr,
                username: document.getElementById('auth_user').value.trim(),
                password: document.getElementById('auth_pass').value.trim(),
                port: parseInt(document.getElementById('server_port').value) || 8000
            };

            const btn = document.getElementById('btn-save');
            btn.disabled = true;
            btn.innerText = '保存中...';

            try {
                const res = await fetch('/api/config', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                const data = await res.json();
                if (data.success) {
                    showToast('💾 配置保存成功！');
                    document.getElementById('auth_pass').value = '';
                    fetchStatus();
                } else {
                    alert('保存失败: ' + (data.error || '未知错误'));
                }
            } catch (err) {
                alert('保存异常: ' + err.message);
            } finally {
                btn.disabled = false;
                btn.innerText = '💾 保存配置';
            }
        }

        async function runSyncTest() {
            const previewEl = document.getElementById('yaml-preview');
            previewEl.innerText = '⏳ 正在通过代理拉取上游规则并重构转换配置 (请稍候数秒)...';
            const btn = document.getElementById('btn-sync-test');
            if (btn) { btn.disabled = true; btn.innerText = '🔄 转换中...'; }

            try {
                const res = await fetch('/api/test-sync');
                const data = await res.json();
                if (data.success) {
                    const nodesContainer = document.getElementById('nodes-preview-tags');
                    document.getElementById('node-count').innerText = data.nodes.length;
                    nodesContainer.innerHTML = data.nodes.map(n => 
                        `<span class="tag-pill tag-node">${n.name} (${n.type}:${n.port})</span>`
                    ).join(' ') || '<span style="color:var(--text-muted);font-size:12px;">未在 Sing-box 探测到有效代理入站</span>';

                    document.getElementById('del-group-count').innerText = data.summary.deleted_groups_count;
                    document.getElementById('del-groups-tags').innerHTML = (data.summary.deleted_groups || []).map(g =>
                        `<span class="tag-pill tag-del">${g}</span>`
                    ).join(' ') || '<span style="color:var(--text-muted);">无</span>';

                    document.getElementById('keep-group-count').innerText = data.summary.kept_groups_count;
                    document.getElementById('keep-groups-tags').innerHTML = (data.summary.kept_groups || []).map(g =>
                        `<span class="tag-pill tag-keep">${g}</span>`
                    ).join(' ');

                    previewEl.innerText = data.yaml;
                } else {
                    previewEl.innerText = '转换失败: ' + data.error;
                }
            } catch (err) {
                previewEl.innerText = '测试请求异常: ' + err.message;
            } finally {
                if (btn) { btn.disabled = false; btn.innerText = '🔄 立即测试转换'; }
            }
        }

        async function logout() {
            await fetch('/logout', { method: 'POST' });
            window.location.href = '/login';
        }

        // Initialize immediately
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', fetchStatus);
        } else {
            fetchStatus();
        }
    </script>
</body>
</html>
"""
