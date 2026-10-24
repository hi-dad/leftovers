// usage: node capture.mjs <html> <outDir> <fps|list:t1,t2,...>
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const [html, outDir, spec] = process.argv.slice(2);
mkdirSync(outDir, { recursive: true });
const times = spec.startsWith('list:') ? spec.slice(5).split(',').map(Number)
  : Array.from({ length: Math.round((+process.env.DUR || 30) * +spec) }, (_, i) => i / +spec);
const port = 9300 + Math.floor(Math.random() * 500);
const prof = mkdtempSync(join(tmpdir(), 'adprof-'));
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, '--window-size=1200,675',
  '--hide-scrollbars', '--allow-file-access-from-files', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, id = 0; const pending = new Map();
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
try {
  let target;
  for (let i = 0; i < 50 && !target; i++) { await sleep(200); try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); } catch {} }
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } });
  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1200, height: 675, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: 'file://' + resolve(html) + '?capture' + (process.env.Q || '') });
  for (let i = 0; i < 40; i++) { await sleep(150); const r = await send('Runtime.evaluate', { expression: "document.body&&document.body.dataset.ready", returnByValue: true }); if (r?.result?.value === '1') break; }
  await sleep(500);
  for (let i = 0; i < times.length; i++) {
    await send('Runtime.evaluate', { expression: `renderAt(${times[i]})` });
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(outDir, `f${String(i).padStart(4, '0')}.png`), Buffer.from(shot.data, 'base64'));
  }
  console.log('frames', times.length);
} finally { try { ws && ws.close(); } catch {} chrome.kill('SIGKILL'); }
process.exit(0);
