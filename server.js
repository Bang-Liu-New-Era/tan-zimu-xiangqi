/*
 * server.js — 零依赖静态服务器 (同时可选接入原生开源引擎)
 *
 * 运行: node server.js   然后浏览器打开 http://localhost:3000
 *
 * 默认: 前端在浏览器内用 Web Worker 运行内置 JS 棋力引擎 (ai.js)，
 *       每步思考时间受 DIFF_BUDGET 控制 (最高 1.8s)，满足 ≤3s 要求。
 *
 * 可选接入原生开源引擎 (如 Pikafish / ElephantEye):
 *   1) 下载引擎二进制 (例如 Pikafish, https://github.com/official-pikafish/Pikafish)
 *      并准备好其 NNUE 权重文件 (pikafish.nnue)；
 *   2) 设置环境变量后启动:
 *        ENGINE_PATH=/abs/path/pikafish ENGINE_PROTOCOL=uci node server.js
 *   3) 浏览器访问 http://localhost:3000/?useEngine=1
 *  说明: 该路径为实验性，需联网获取二进制；坐标约定可能需按引擎微调
 *        (见 ucciToIndex / indexToUcci)。
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const ROOT = __dirname;
const PORT = process.env.PORT || 3000;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.ico': 'image/x-icon',
};

function safeJoin(urlPath) {
  if (urlPath === '/') return path.join(ROOT, 'public', 'index.html');
  const p = urlPath.replace(/^\/+/, '');
  const full = path.join(ROOT, p);
  if (full !== ROOT && !full.startsWith(ROOT + path.sep)) return null; // 防目录穿越
  return full;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (req.method === 'POST' && url.pathname === '/api/engine/move') {
    return handleEngineMove(req, res);
  }
  const filePath = safeJoin(url.pathname);
  if (!filePath) { res.writeHead(403); return res.end('Forbidden'); }
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not Found'); }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
});

// ---------- 可选: 原生开源引擎 (UCI) ----------
const ENGINE_PATH = process.env.ENGINE_PATH || null;
const ENGINE_PROTOCOL = (process.env.ENGINE_PROTOCOL || 'uci').toLowerCase();
let engineProc = null;

function ensureEngine() {
  if (engineProc || !ENGINE_PATH) return engineProc;
  engineProc = spawn(ENGINE_PATH, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  engineProc.stdin.write('uci\n');
  let buf = '';
  engineProc.stdout.on('data', d => { buf += d.toString(); });
  engineProc.stderr.on('data', () => {});
  return engineProc;
}

function ucciToIndex(sq) {
  // 约定(可按引擎调整): 文件 a..i -> 列 0..8, 数字 -> 行 0..9 (行0在顶部)
  const FILES = 'abcdefghi';
  const c = FILES.indexOf(sq[0]);
  const r = parseInt(sq.slice(1), 10);
  return r * 9 + c;
}

function handleEngineMove(req, res) {
  if (!ENGINE_PATH) {
    res.writeHead(501, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: '未配置 ENGINE_PATH' }));
  }
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    let payload;
    try { payload = JSON.parse(body); } catch (e) {
      res.writeHead(400); return res.end('Bad Request');
    }
    const board = Int8Array.from(payload.board);
    const turn = payload.turn === 'b' ? 'b' : 'r';
    const budget = Math.min(payload.budget || 1800, 2800);
    const eng = ensureEngine();

    // 借助内置规则引擎生成 FEN
    const X = require('./engine/xiangqi.js');
    const fen = X.boardToFen(board, turn);

    let out = '', bestmove = null, done = false;
    const onData = (d) => {
      out += d.toString();
      const lines = out.split('\n');
      for (const line of lines) {
        if (line.startsWith('bestmove')) {
          const parts = line.trim().split(/\s+/);
          if (parts[1] && parts[1] !== '(none)') bestmove = parts[1];
          if (!done) { done = true; finish(); }
        }
      }
    };
    eng.stdout.removeAllListeners('data');
    eng.stdout.on('data', onData);

    function finish() {
      eng.stdout.removeAllListeners('data');
      if (!bestmove) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({}));
      }
      const from = ucciToIndex(bestmove.slice(0, 2));
      const to = ucciToIndex(bestmove.slice(2, 4));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ from, to }));
    }

    eng.stdin.write('position fen ' + fen + '\n');
    eng.stdin.write('go movetime ' + budget + '\n');
    // 安全超时
    setTimeout(() => { if (!done) { done = true; finish(); } }, budget + 800);
  });
}

server.listen(PORT, () => {
  console.log('中国象棋已启动: http://localhost:' + PORT);
  if (ENGINE_PATH) console.log('已接入外部引擎:', ENGINE_PATH, '(协议:', ENGINE_PROTOCOL + ')');
  else console.log('使用内置 JS 棋力引擎 (浏览器 Web Worker)。');
});
