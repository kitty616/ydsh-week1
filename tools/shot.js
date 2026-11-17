#!/usr/bin/env node
/**
 * 通用网页截图工具（基于 Chrome DevTools Protocol，不依赖 puppeteer）
 *
 * 为什么自己写：项目里要截的页面有三类——
 *   1. 本地静态 HTML（ECharts 大屏，file:// 打开，需要整页 1920×1080）
 *   2. 需要登录的后台页（Superset 仪表板）
 *   3. Streamlit（WebSocket 驱动，headless 下偶发连不上，只能截首屏骨架）
 * 用 CDP 直连而不是 puppeteer，是因为本机没有 Chrome，只有 Edge；
 * CDP 只要求浏览器支持 --remote-debugging-port，与品牌无关，也省掉
 * 一个 300MB 的 node_modules。
 *
 * 用法：
 *   node tools/shot.js --url http://localhost:8088/login/ \
 *        --login admin:Ydsh@2026 \
 *        --goto http://localhost:8088/superset/dashboard/ydsh-week4-ops/ \
 *        --out docs/images/w4_superset.png --width 1600 --height 1000 --full
 *
 * 参数：
 *   --url      先打开的地址（登录页）
 *   --login    user:pass，给了就自动填表提交
 *   --goto     登录后要截的地址
 *   --out      输出 png 路径
 *   --width/--height  视口尺寸
 *   --full     整页截图（默认只截视口）
 *   --wait     截图前额外等待毫秒（默认 5000）
 */
'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

// ---------------------------------------------------------------- 参数

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) continue;
    const name = key.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[name] = true;
    } else {
      out[name] = next;
      i += 1;
    }
  }
  return out;
}

const args = parseArgs(process.argv);
const URL_LOGIN = args.url || 'about:blank';
const TARGET = args.goto || URL_LOGIN;
const OUT = args.out || 'shot.png';
const W = parseInt(args.width, 10) || 1600;
const H = parseInt(args.height, 10) || 1000;
const FULL = !!args.full;
const WAIT = parseInt(args.wait, 10) || 5000;
const PORT = 9222 + Math.floor(Math.random() * 300);

const EDGE_CANDIDATES = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  '/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
];

function findBrowser() {
  for (const p of EDGE_CANDIDATES) {
    const norm = p.replace(/^\/c\//, 'C:/');
    if (fs.existsSync(norm)) return norm;
  }
  throw new Error('找不到 msedge.exe，请手动在 EDGE_CANDIDATES 里补路径');
}

// ---------------------------------------------------------------- CDP

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function httpJson(urlPath, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port: PORT, path: urlPath, method },
      (res) => {
        let buf = '';
        res.on('data', (c) => (buf += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(buf));
          } catch (e) {
            reject(new Error(`${urlPath} 返回非 JSON: ${buf.slice(0, 200)}`));
          }
        });
      },
    );
    req.on('error', reject);
    req.end();
  });
}

class Session {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      }
    });
  }

  send(method, params = {}) {
    this.id += 1;
    const id = this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`${method} 超时`));
        }
      }, 60000);
    });
  }

  async evaluate(expression, awaitPromise = true) {
    const r = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise,
      returnByValue: true,
      userGesture: true,
    });
    if (r.exceptionDetails) {
      throw new Error(r.exceptionDetails.text + ' ' + JSON.stringify(r.exceptionDetails.exception || {}));
    }
    return r.result ? r.result.value : undefined;
  }
}

async function main() {
  const browserPath = findBrowser();
  const profile = path.join('.tmp', `edge-profile-${PORT}`);
  fs.mkdirSync(profile, { recursive: true });

  const child = spawn(
    browserPath,
    [
      '--headless=new',
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${path.resolve(profile)}`,
      `--window-size=${W},${H}`,
      '--hide-scrollbars',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-features=Translate,MediaRouter',
      'about:blank',
    ],
    { stdio: 'ignore', detached: false },
  );

  // 等调试端口起来
  let version = null;
  for (let i = 0; i < 60; i += 1) {
    try {
      version = await httpJson('/json/version');
      break;
    } catch (e) {
      await sleep(300);
    }
  }
  if (!version) throw new Error('浏览器调试端口未就绪');

  const page = await httpJson('/json/new?about:blank', 'PUT');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener('open', res);
    ws.addEventListener('error', rej);
  });

  const s = new Session(ws);
  await s.send('Page.enable');
  await s.send('Runtime.enable');
  await s.send('Emulation.setDeviceMetricsOverride', {
    width: W,
    height: H,
    deviceScaleFactor: 1,
    mobile: false,
  });

  console.log(`[shot] 浏览器 ${path.basename(browserPath)} 视口 ${W}x${H}`);

  // ---- 登录
  if (args.login) {
    const [user, pass] = String(args.login).split(':');
    await s.send('Page.navigate', { url: URL_LOGIN });
    await sleep(2500);
    const res = await s.evaluate(`(() => {
      const u = document.querySelector('input[name=username], input[name=email], #username');
      const p = document.querySelector('input[name=password], #password');
      if (!u || !p) return 'no-form';
      u.focus(); u.value = ${JSON.stringify(user)};
      p.focus(); p.value = ${JSON.stringify(pass)};
      const f = u.closest('form');
      if (!f) return 'no-form-node';
      f.submit();
      return 'submitted';
    })()`);
    console.log('[shot] 登录：', res);
    await sleep(3000);
  }

  // ---- 目标页
  await s.send('Page.navigate', { url: TARGET });
  await sleep(WAIT);

  // 等 ECharts / SVG / canvas 画完：看页面里有没有还在转的 loading
  for (let i = 0; i < 20; i += 1) {
    const busy = await s.evaluate(`(() => {
      const t = document.body ? document.body.innerText : '';
      return /Waiting on|加载中|Loading/.test(t);
    })()`);
    if (!busy) break;
    await sleep(1000);
  }
  await sleep(500);

  // ---- 可选：在指定坐标点一下、输入一句话、回车（用来截"提问后"的界面）
  if (args.ask) {
    const [ax, ay] = String(args['ask-at'] || '1027,924').split(',').map(Number);
    await s.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: ax, y: ay, button: 'none' });
    await sleep(200);
    for (const type of ['mousePressed', 'mouseReleased']) {
      await s.send('Input.dispatchMouseEvent', {
        type, x: ax, y: ay, button: 'left',
        buttons: type === 'mousePressed' ? 1 : 0, clickCount: 1,
      });
      await sleep(100);
    }
    await sleep(400);
    await s.send('Input.insertText', { text: String(args.ask) });
    await sleep(300);
    for (const type of ['keyDown', 'keyUp']) {
      await s.send('Input.dispatchKeyEvent', {
        type, key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13,
        text: type === 'keyDown' ? '\r' : undefined,
      });
      await sleep(80);
    }
    console.log(`[shot] 已提问：${args.ask}`);
    await sleep(parseInt(args['ask-wait'], 10) || 15000);
  }

  // ---- 可选：点击某个坐标（用来验证图表联动 / 下钻）
  if (args.click) {
    const [cx, cy] = String(args.click).split(',').map(Number);
    // 先 mouseMoved：ECharts 只在指针已进入画布时才把 pressed/released
    // 合成 click，少了这一步只有 hover 提示、不会触发点击回调。
    await s.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx, y: cy, button: 'none' });
    await sleep(300);
    for (const type of ['mousePressed', 'mouseReleased']) {
      await s.send('Input.dispatchMouseEvent', {
        type,
        x: cx,
        y: cy,
        button: 'left',
        buttons: type === 'mousePressed' ? 1 : 0,
        clickCount: 1,
      });
      await sleep(120);
    }
    console.log(`[shot] 已点击 (${cx}, ${cy})`);
    await sleep(parseInt(args['click-wait'], 10) || 4000);
  }

  const metrics = await s.send('Page.getLayoutMetrics');
  const size = metrics.cssContentSize || metrics.contentSize;
  const clip = FULL
    ? { x: 0, y: 0, width: W, height: Math.max(H, Math.ceil(size.height)), scale: 1 }
    : { x: 0, y: 0, width: W, height: H, scale: 1 };

  const shot = await s.send('Page.captureScreenshot', {
    format: 'png',
    captureBeyondViewport: FULL,
    clip,
  });

  fs.mkdirSync(path.dirname(path.resolve(OUT)), { recursive: true });
  fs.writeFileSync(OUT, Buffer.from(shot.data, 'base64'));
  console.log(`[shot] 已保存 ${OUT}  ${clip.width}x${clip.height}`);

  ws.close();
  child.kill();
  await sleep(300);
  process.exit(0);
}

main().catch((err) => {
  console.error('[shot] 失败：', err.message);
  process.exit(1);
});
