/**
 * System Logger Module for Cloudflare VLESS Proxy
 * 记录运行时日志与所有异常错误分支，持久化至 Cloudflare KV 中供管理面板实时查看
 */

const LOGS_KV_KEY = '__SYSTEM_LOGS__';
const MAX_LOGS_COUNT = 150;

// 内存中缓存的日志（针对无 KV 绑定的降级运行环境）
let memoryLogs = [];

/**
 * 记录一条系统日志
 * @param {object} env Cloudflare Worker 环境变量
 * @param {object} logEntry { level: 'ERROR'|'WARN'|'INFO', module: string, message: string, details?: any, ip?: string }
 */
export async function logSystem(env, { level = 'INFO', module = 'System', message = '', details = null, ip = '' }) {
  const logItem = {
    id: `${Date.now()}-${Math.random().toString(36).substring(2, 7)}`,
    timestamp: new Date().toISOString(),
    level: String(level).toUpperCase(),
    module: String(module),
    message: String(message),
    details: details ? (typeof details === 'object' ? JSON.stringify(details) : String(details)) : undefined,
    ip: ip || undefined,
  };

  // 控制台标准输出
  const consoleMsg = `[${logItem.timestamp}] [${logItem.level}] [${logItem.module}] ${logItem.message}${logItem.details ? ' ' + logItem.details : ''}`;
  if (logItem.level === 'ERROR') {
    console.error(consoleMsg);
  } else if (logItem.level === 'WARN') {
    console.warn(consoleMsg);
  } else {
    console.log(consoleMsg);
  }

  // 内存记录
  memoryLogs.unshift(logItem);
  if (memoryLogs.length > MAX_LOGS_COUNT) {
    memoryLogs.length = MAX_LOGS_COUNT;
  }

  // 持久化至 Cloudflare KV
  if (env && env.CONFIG_KV && typeof env.CONFIG_KV.get === 'function' && typeof env.CONFIG_KV.put === 'function') {
    try {
      let kvLogs = [];
      const raw = await env.CONFIG_KV.get(LOGS_KV_KEY);
      if (raw) {
        try {
          kvLogs = JSON.parse(raw);
          if (!Array.isArray(kvLogs)) kvLogs = [];
        } catch (_) {
          kvLogs = [];
        }
      }
      kvLogs.unshift(logItem);
      if (kvLogs.length > MAX_LOGS_COUNT) {
        kvLogs.length = MAX_LOGS_COUNT;
      }
      await env.CONFIG_KV.put(LOGS_KV_KEY, JSON.stringify(kvLogs));
    } catch (err) {
      console.error('Failed to persist log to KV:', err.message);
    }
  }
}

/**
 * 获取系统日志列表
 * @param {object} env 
 * @param {number} limit 
 * @returns {Promise<Array>}
 */
export async function getSystemLogs(env, limit = 100) {
  if (env && env.CONFIG_KV && typeof env.CONFIG_KV.get === 'function') {
    try {
      const raw = await env.CONFIG_KV.get(LOGS_KV_KEY);
      if (raw) {
        const logs = JSON.parse(raw);
        if (Array.isArray(logs)) {
          return logs.slice(0, limit);
        }
      }
    } catch (err) {
      console.error('Failed to read logs from KV:', err.message);
    }
  }
  return memoryLogs.slice(0, limit);
}

/**
 * 清空系统日志
 * @param {object} env 
 * @returns {Promise<boolean>}
 */
export async function clearSystemLogs(env) {
  memoryLogs = [];
  if (env && env.CONFIG_KV && typeof env.CONFIG_KV.delete === 'function') {
    try {
      await env.CONFIG_KV.delete(LOGS_KV_KEY);
      return true;
    } catch (err) {
      console.error('Failed to clear logs in KV:', err.message);
      return false;
    }
  }
  return true;
}
