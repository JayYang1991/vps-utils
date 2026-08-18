/**
 * Cloudflare Worker Bundler & High-Performance Obfuscator
 * 1. Bundles all modules into single standalone ESM code via esbuild
 * 2. Applies AST obfuscation with String Array Base64 Encryption & Identifier Mangling
 * 3. Writes final obfuscated artifact to dist/index.js
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

  console.log('🛡️ [2/2] Applying AST obfuscation & string encryption...');

  const obfuscatedResult = JavaScriptObfuscator.obfuscate(bundledCode, {
    compact: true,
    controlFlowFlattening: false,
    deadCodeInjection: false,
    debugProtection: false,
    disableConsoleOutput: false,
    identifierNamesGenerator: 'hexadecimal',
    log: false,
    numbersToExpressions: true,
    renameGlobals: false,
    rotateStringArray: true,
    selfDefending: false,
    simplify: true,
    splitStrings: false,
    stringArray: true,
    stringArrayCallsTransform: true,
    stringArrayCallsTransformThreshold: 0.8,
    stringArrayEncoding: ['base64'],
    stringArrayIndexShift: true,
    stringArrayRotate: true,
    stringArrayShuffle: true,
    stringArrayWrappersCount: 2,
    stringArrayWrappersChainedCalls: true,
    stringArrayWrappersParametersMaxCount: 4,
    stringArrayWrappersType: 'function',
    stringArrayThreshold: 0.85,
    transformObjectKeys: true,
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
