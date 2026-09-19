/* build_single.js — 把引擎/AI/界面打包成一个可双击打开的离线 HTML */
'use strict';
const fs = require('fs');
const path = require('path');

const root = __dirname;
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const xiangqi = read('engine/xiangqi.js');
const ai = read('engine/ai.js');
const css = read('public/style.css');
const app = read('app_standalone.js');

const markup = `<div class="app">
    <header>
      <h1>🐴 人机中国象棋</h1>
      <p class="subtitle">单机离线版 · 电脑每步思考不超过 3 秒 · 双击即可运行</p>
    </header>

    <div class="main">
      <div class="board-wrap">
        <canvas id="board"></canvas>
        <div id="status" class="status">轮到 <b>红方</b> 走棋</div>
      </div>

      <aside class="panel">
        <div class="controls">
          <button id="newGame" class="btn primary">重新开始</button>
          <button id="undo" class="btn">悔棋</button>
          <button id="resign" class="btn">认输</button>
        </div>

        <div class="field">
          <label>先手：</label>
          <select id="side">
            <option value="r">我执红（先走）</option>
            <option value="b">我执黑（后走）</option>
          </select>
        </div>

        <div class="field">
          <label>难度：</label>
          <select id="difficulty">
            <option value="easy">入门（约 0.4 秒）</option>
            <option value="medium">进阶（约 1.0 秒）</option>
            <option value="hard" selected>高手（约 1.8 秒）</option>
          </select>
        </div>

        <div id="thinking" class="thinking hidden">
          <div class="spinner"></div>
          <span id="thinkingText">电脑思考中… 0.0s</span>
        </div>

        <div class="scoreboard">
          <div class="sb"><span class="sb-label">红方用时</span><span id="redTime" class="sb-val">0.0s</span></div>
          <div class="sb"><span class="sb-label">黑方用时</span><span id="blackTime" class="sb-val">0.0s</span></div>
        </div>

        <div class="moves">
          <div class="moves-head">走法记录（每一步）</div>
          <ol id="moveList" class="move-list"></ol>
        </div>
      </aside>
    </div>

    <div id="result" class="result hidden">
      <div class="result-box">
        <div id="resultText" class="result-text"></div>
        <button id="resultNew" class="btn primary">再来一局</button>
      </div>
    </div>
  </div>`;

const html =
`<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>人机中国象棋（单机离线版）</title>
  <style>
${css}
  </style>
</head>
<body>
${markup}

  <!-- 规则引擎与 AI（同一份源码既供主线程，也供离线 Worker 复用） -->
  <script id="libs-xq">
${xiangqi}
  </script>
  <script id="libs-ai">
${ai}
  </script>
  <script>
${app}
  </script>
</body>
</html>`;

const out = path.join(root, '象棋单机版.html');
fs.writeFileSync(out, html, 'utf8');
console.log('已生成:', out, '(', (html.length / 1024).toFixed(1), 'KB )');
