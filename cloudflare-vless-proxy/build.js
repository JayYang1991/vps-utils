/**
 * High-Performance Cloudflare Worker Bundler & AST Obfuscator
 * Optimized for Cloudflare Edge Runtime (Zero CPU lag, sub-millisecond cold start)
 * 1. Bundles all modules into single ESM file via esbuild
 * 2. Applies AST obfuscation with String Array Base64 Encryption & Identifier Mangling
 * 3. Strips all comments, removes dead code, and produces dist/index.js
 */

import esbuild from 'esbuild';
import JavaScriptObfuscator from 'javascript-obfuscator';
import fs from 'node:fs';
import path from 'node:path';

const distDir = path.resolve('dist');
if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir, { recursive: true });
}

async function buildAndObfuscate() {
  console.log('⚡ [1/2] Bundling source modules via esbuild...');

  const bundleResult = await esbuild.build({
    entryPoints: ['src/index.js'],
    bundle: true,
    write: false,
    format: 'esm',
    target: 'es2022',
    external: ['cloudflare:sockets'],
    platform: 'neutral',
    legalComments: 'none',
  });

  const bundledCode = bundleResult.outputFiles[0].text;
  console.log(`📦 Bundled code size: ${(Buffer.byteLength(bundledCode, 'utf-8') / 1024).toFixed(2)} KB`);

  console.log('🛡️ [2/2] Applying Cloudflare-optimized AST obfuscation & string encryption...');

  // 使用针对边缘环境优化的低 CPU 开销混淆策略（避免 numbersToExpressions 消耗边缘执行时间）
  const obfuscatedResult = JavaScriptObfuscator.obfuscate(bundledCode, {
    compact: true,
    controlFlowFlattening: false,
    deadCodeInjection: false,
    debugProtection: false,
    disableConsoleOutput: false,
    identifierNamesGenerator: 'hexadecimal',
    log: false,
    numbersToExpressions: false, // 禁用数字算式展开，保证 V8 引擎极致执行性能
    renameGlobals: false,
    rotateStringArray: true,
    selfDefending: false,
    simplify: true,
    splitStrings: false,
    stringArray: true,
    stringArrayCallsTransform: false, // 禁用多层函数包裹调用，消除 CPU 瓶颈
    stringArrayEncoding: ['base64'],
    stringArrayIndexShift: true,
    stringArrayRotate: true,
    stringArrayShuffle: true,
    stringArrayWrappersCount: 1,
    stringArrayWrappersType: 'variable',
    stringArrayThreshold: 0.8, // 80% 核心特征字符串全量 Base64 编码
    transformObjectKeys: false, // 保持内置对象操作高效
    unicodeEscapeSequence: false,
    target: 'browser-no-eval',
  });

  const finalCode = obfuscatedResult.getObfuscatedCode();
  const distFile = path.join(distDir, 'index.js');
  fs.writeFileSync(distFile, finalCode, 'utf-8');

  const finalSize = (Buffer.byteLength(finalCode, 'utf-8') / 1024).toFixed(2);
  console.log(`✨ [DONE] Production obfuscated artifact created at: dist/index.js (${finalSize} KB)`);
}

buildAndObfuscate().catch((err) => {
  console.error('❌ Build failed:', err);
  process.exit(1);
});
