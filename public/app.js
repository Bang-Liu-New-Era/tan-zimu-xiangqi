/* app.js — 人机中国象棋 前端逻辑 */
(function () {
  'use strict';
  const X = window.Xiangqi;
  const { RED, BLACK, EMPTY } = X;
  const USE_ENGINE = /[?&]useEngine=1/.test(location.search);

  // 画布尺寸 (CSS 像素)
  const CELL = 60, M = 30;
  const CSSW = 8 * CELL + 2 * M;   // 540
  const CSSH = 9 * CELL + 2 * M;   // 600

  const PIECE_CHAR = {
    1: '帅', 2: '仕', 3: '相', 4: '马', 5: '车', 6: '炮', 7: '兵',
    9: '将', 10: '士', 11: '象', 12: '马', 13: '车', 14: '炮', 15: '卒'
  };

  const DIFF_BUDGET = { easy: 400, medium: 1000, hard: 1800 };

  // ---------- 状态 ----------
  let board, turn, humanColor, selected, legalTargets;
  let history, lastMove, over, repCount, moveLog;
  let aiThinking = false, difficulty = 'hard';
  let redTime = 0, blackTime = 0, turnTimerStart = 0;
  let worker = null, thinkingRAF = 0, thinkingStart = 0;
  let capFx = null; // 吃子特效: {sq, start}

  // ---------- DOM ----------
  const canvas = document.getElementById('board');
  const ctx = canvas.getContext('2d');
  const statusEl = document.getElementById('status');
  const thinkingEl = document.getElementById('thinking');
  const thinkingText = document.getElementById('thinkingText');
  const redTimeEl = document.getElementById('redTime');
  const blackTimeEl = document.getElementById('blackTime');
  const moveListEl = document.getElementById('moveList');
  const resultEl = document.getElementById('result');
  const resultTextEl = document.getElementById('resultText');

  function setupCanvas() {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = CSSW * dpr;
    canvas.height = CSSH * dpr;
    canvas.style.width = CSSW + 'px';
    canvas.style.height = CSSH + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  // ---------- 坐标换算 ----------
  function cx(c) { return M + c * CELL; }
  function cy(r) { return M + r * CELL; }
  function eventToRC(ev) {
    const rect = canvas.getBoundingClientRect();
    const x = (ev.clientX - rect.left) * (CSSW / rect.width);
    const y = (ev.clientY - rect.top) * (CSSH / rect.height);
    let c = Math.round((x - M) / CELL);
    let r = Math.round((y - M) / CELL);
    if (r < 0 || r > 9 || c < 0 || c > 8) return null;
    return { r, c };
  }

  // ---------- 绘制 ----------
  function drawBoard() {
    ctx.clearRect(0, 0, CSSW, CSSH);
    ctx.fillStyle = '#e8b974';
    ctx.fillRect(0, 0, CSSW, CSSH);

    ctx.strokeStyle = '#5a3a1a';
    ctx.lineWidth = 1.4;

    // 横线
    for (let r = 0; r < 10; r++) {
      ctx.beginPath();
      ctx.moveTo(cx(0), cy(r));
      ctx.lineTo(cx(8), cy(r));
      ctx.stroke();
    }
    // 竖线 (中间 7 条在河界处断开)
    for (let c = 0; c < 9; c++) {
      if (c === 0 || c === 8) {
        ctx.beginPath();
        ctx.moveTo(cx(c), cy(0));
        ctx.lineTo(cx(c), cy(9));
        ctx.stroke();
      } else {
        ctx.beginPath(); ctx.moveTo(cx(c), cy(0)); ctx.lineTo(cx(c), cy(4)); ctx.stroke();
        ctx.beginPath(); ctx.moveTo(cx(c), cy(5)); ctx.lineTo(cx(c), cy(9)); ctx.stroke();
      }
    }
    // 九宫斜线
    drawPalace(0, 2);
    drawPalace(7, 9);
    // 河界文字
    ctx.fillStyle = '#7a4a1a';
    ctx.font = '22px "KaiTi","STKaiti",serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText('楚　河', cx(1.5), cy(4.5));
    ctx.fillText('漢　界', cx(6.5), cy(4.5));

    // 高亮
    drawHighlights();
    // 棋子
    for (let r = 0; r < 10; r++) {
      for (let c = 0; c < 9; c++) {
        const p = board[X.idx(r, c)];
        if (p !== EMPTY) drawPiece(r, c, p);
      }
    }
  }

  function drawPalace(r0, r1) {
    ctx.beginPath();
    ctx.moveTo(cx(3), cy(r0)); ctx.lineTo(cx(5), cy(r1));
    ctx.moveTo(cx(5), cy(r0)); ctx.lineTo(cx(3), cy(r1));
    ctx.stroke();
  }

  function drawHighlights() {
    if (lastMove) {
      for (const sq of [lastMove.from, lastMove.to]) {
        const [r, c] = X.rc(sq);
        ctx.fillStyle = 'rgba(46,125,107,0.28)';
        ctx.fillRect(cx(c) - CELL / 2, cy(r) - CELL / 2, CELL, CELL);
      }
    }
    if (selected !== null) {
      const [r, c] = X.rc(selected);
      ctx.strokeStyle = '#f1c40f';
      ctx.lineWidth = 3;
      ctx.strokeRect(cx(c) - CELL / 2 + 2, cy(r) - CELL / 2 + 2, CELL - 4, CELL - 4);
    }
    if (legalTargets) {
      for (const t of legalTargets) {
        const [r, c] = X.rc(t);
        const occupied = board[t] !== EMPTY;
        ctx.fillStyle = 'rgba(192,57,43,0.85)';
        if (occupied) {
          ctx.beginPath();
          ctx.arc(cx(c), cy(r), CELL * 0.42, 0, Math.PI * 2);
          ctx.strokeStyle = 'rgba(192,57,43,0.9)';
          ctx.lineWidth = 3; ctx.stroke();
        } else {
          ctx.beginPath();
          ctx.arc(cx(c), cy(r), 7, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }
    // 吃子特效: 目标格红色扩散圆环 + “吃”
    if (capFx) {
      const dt = Date.now() - capFx.start;
      if (dt < 600) {
        const [r, c] = X.rc(capFx.sq);
        const p = dt / 600;
        const rad = CELL * 0.18 + p * CELL * 0.42;
        ctx.save();
        ctx.strokeStyle = 'rgba(214,69,49,' + (1 - p) + ')';
        ctx.lineWidth = 5;
        ctx.beginPath();
        ctx.arc(cx(c), cy(r), rad, 0, Math.PI * 2);
        ctx.stroke();
        ctx.fillStyle = 'rgba(214,69,49,' + (1 - p).toFixed(2) + ')';
        ctx.font = 'bold 22px "KaiTi","STKaiti",serif';
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText('吃', cx(c), cy(r) - CELL * 0.62);
        ctx.restore();
      }
    }
  }

  // 吃子特效动画循环（约 0.6 秒）
  function kickFx() {
    requestAnimationFrame(function step() {
      drawBoard();
      if (capFx && Date.now() - capFx.start < 600) requestAnimationFrame(step);
      else { capFx = null; drawBoard(); }
    });
  }

  function drawPiece(r, c, code) {
    const x = cx(c), y = cy(r);
    const rad = CELL * 0.40;
    // 圆盘
    ctx.beginPath();
    ctx.arc(x, y, rad, 0, Math.PI * 2);
    ctx.fillStyle = '#f7eccb';
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = X.colorOf(code) === RED ? '#c0392b' : '#2b2b2b';
    ctx.stroke();
    // 文字
    ctx.fillStyle = X.colorOf(code) === RED ? '#c0392b' : '#2b2b2b';
    ctx.font = 'bold 30px "KaiTi","STKaiti","PingFang SC",serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(PIECE_CHAR[code], x, y + 1);
  }

  // ---------- 交互 ----------
  function onCanvasClick(ev) {
    if (over || aiThinking) return;
    if (turn !== humanColor) return;
    const rc = eventToRC(ev);
    if (!rc) return;
    const i = X.idx(rc.r, rc.c);

    if (selected === null) {
      if (board[i] !== EMPTY && X.colorOf(board[i]) === humanColor) {
        selected = i;
        legalTargets = X.generateLegalMoves(board, humanColor)
          .filter(m => m.from === i).map(m => m.to);
        drawBoard();
      }
      return;
    }
    if (i === selected) { clearSelection(); drawBoard(); return; }
    if (board[i] !== EMPTY && X.colorOf(board[i]) === humanColor) {
      selected = i;
      legalTargets = X.generateLegalMoves(board, humanColor)
        .filter(m => m.from === i).map(m => m.to);
      drawBoard(); return;
    }
    if (legalTargets.includes(i)) {
      doMove({ from: selected, to: i, piece: board[selected], capture: board[i] !== EMPTY }, humanColor);
    }
    clearSelection();
    drawBoard();
  }

  function clearSelection() { selected = null; legalTargets = null; }

  // ---------- 走子 / 局面更新 ----------
  function snapshot() {
    return {
      board: Int8Array.from(board),
      turn, humanColor, lastMove,
      over, repCount: Object.assign({}, repCount),
      redTime, blackTime, moveLog: moveLog.slice()
    };
  }

  function doMove(move, mover) {
    history.push(snapshot());
    // 计时
    const dt = Date.now() - turnTimerStart;
    if (mover === RED) redTime += dt; else blackTime += dt;

    // 记谱
    const text = X.moveToNotation(board, move, mover);
    moveLog.push({ color: mover, text });

    board = X.applyMove(board, move);
    lastMove = { from: move.from, to: move.to };
    if (move.capture) capFx = { sq: move.to, start: Date.now() };
    turn = X.opponent(mover);

    // 重复局面检测
    const key = X.boardHash(board, turn);
    repCount[key] = (repCount[key] || 0) + 1;

    updateTimers(); renderMoveLog();
    drawBoard();
    if (capFx) kickFx();

    if (repCount[key] >= 3) { endGame('和棋（三次重复局面）'); return; }

    // 终局检测 (轮到走子的一方无合法着法)
    const moves = X.generateLegalMoves(board, turn);
    if (moves.length === 0) {
      const chk = X.isInCheck(board, turn);
      const winner = X.opponent(turn);
      endGame((winner === RED ? '红方' : '黑方') + '胜（' + (chk ? '将死' : '困毙') + '）');
      return;
    }
    updateStatus();
    if (turn !== humanColor) startAI();
    else turnTimerStart = Date.now();
  }

  // ---------- AI ----------
  function startAI() {
    if (over) return;
    aiThinking = true;
    thinkingEl.classList.remove('hidden');
    thinkingStart = Date.now();
    turnTimerStart = Date.now();
    updateStatus();
    tickThinking();
    if (USE_ENGINE) { fetchEngineMove(); return; }
    if (!worker) {
      worker = new Worker('/public/worker.js');
      worker.onmessage = onWorkerResult;
      worker.onerror = function () { /* 忽略，下面兜底 */ };
    }
    worker.postMessage({
      board: board, turn: turn,
      budget: DIFF_BUDGET[difficulty], maxDepth: 8
    });
  }

  function tickThinking() {
    const el = (Date.now() - thinkingStart) / 1000;
    thinkingText.textContent = '电脑思考中… ' + el.toFixed(1) + 's';
    thinkingRAF = requestAnimationFrame(tickThinking);
  }

  function fetchEngineMove() {
    fetch('/api/engine/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ board: Array.from(board), turn: turn, budget: DIFF_BUDGET[difficulty] })
    }).then(r => r.json()).then(res => {
      cancelAnimationFrame(thinkingRAF);
      thinkingEl.classList.add('hidden');
      aiThinking = false;
      if (!res || res.from === undefined) { updateStatus(); return; }
      const move = { from: res.from, to: res.to, piece: board[res.from], capture: board[res.to] !== EMPTY };
      if (!X.generateLegalMoves(board, turn).some(m => m.from === move.from && m.to === move.to)) {
        const legal = X.generateLegalMoves(board, turn);
        if (!legal.length) { updateStatus(); return; }
        move.from = legal[0].from; move.to = legal[0].to;
      }
      doMove(move, turn);
    }).catch(() => {
      thinkingEl.classList.add('hidden'); aiThinking = false; updateStatus();
    });
  }

  function onWorkerResult(e) {    cancelAnimationFrame(thinkingRAF);
    thinkingEl.classList.add('hidden');
    aiThinking = false;
    const res = e.data;
    let move = null;
    if (res && res.from !== undefined) {
      move = { from: res.from, to: res.to, piece: board[res.from], capture: board[res.to] !== EMPTY };
    }
    if (!move || !X.generateLegalMoves(board, turn).some(m => m.from === move.from && m.to === move.to)) {
      // 兜底: 取任意合法着法
      const legal = X.generateLegalMoves(board, turn);
      if (legal.length) move = legal[0];
    }
    if (!move) { updateStatus(); return; }
    doMove(move, turn);
  }

  // ---------- 控件 ----------
  function newGame() {
    board = X.initialBoard();
    turn = RED;
    humanColor = document.getElementById('side').value === 'b' ? BLACK : RED;
    selected = null; legalTargets = null;
    history = []; lastMove = null; over = false;
    repCount = {}; moveLog = [];
    redTime = 0; blackTime = 0;
    resultEl.classList.add('hidden');
    renderMoveLog(); updateTimers();
    updateStatus(); drawBoard();
    if (humanColor === BLACK) startAI(); // 电脑(红)先走
    else turnTimerStart = Date.now();
  }

  function undo() {
    if (aiThinking) return;
    // 悔棋: 退回到玩家上一步之前 (回退最多两步: 电脑应着 + 玩家着)
    let pops = 0;
    while (history.length && pops < 2) {
      const snap = history.pop();
      board = Int8Array.from(snap.board);
      turn = snap.turn; humanColor = snap.humanColor; lastMove = snap.lastMove;
      over = snap.over; repCount = Object.assign({}, snap.repCount);
      redTime = snap.redTime; blackTime = snap.blackTime; moveLog = snap.moveLog.slice();
      pops++;
      if (turn === humanColor) break; // 已回到玩家回合
    }
    if (history.length === 0 && pops === 0) return;
    over = false;
    resultEl.classList.add('hidden');
    renderMoveLog(); updateTimers(); updateStatus(); drawBoard();
    turnTimerStart = Date.now();
  }

  function resign() {
    if (over) return;
    const loser = humanColor;
    endGame((loser === RED ? '黑方' : '红方') + '胜（对方认输）');
  }

  function endGame(text) {
    over = true;
    aiThinking = false;
    cancelAnimationFrame(thinkingRAF);
    thinkingEl.classList.add('hidden');
    resultTextEl.textContent = text;
    resultEl.classList.remove('hidden');
    updateStatus();
  }

  // ---------- 显示 ----------
  function updateStatus() {
    if (over) return;
    const who = turn === RED ? '红方' : '黑方';
    const tag = turn === humanColor ? '（你）' : '（电脑）';
    statusEl.innerHTML = '轮到 <b>' + who + '</b>' + tag + ' 走棋';
  }
  function updateTimers() {
    redTimeEl.textContent = redTime.toFixed(1) + 's';
    blackTimeEl.textContent = blackTime.toFixed(1) + 's';
  }
  function renderMoveLog() {
    moveListEl.innerHTML = '';
    moveLog.forEach((m, i) => {
      const li = document.createElement('li');
      const num = Math.floor(i / 2) + 1;
      const prefix = (i % 2 === 0) ? (num + '.') : (num + '…');
      const cls = m.color === RED ? 'red' : 'black';
      li.innerHTML = '<span class="num">' + prefix + '</span><span class="' + cls + '">' + m.text + '</span>';
      moveListEl.appendChild(li);
    });
    moveListEl.scrollTop = moveListEl.scrollHeight;
  }

  // ---------- 绑定 ----------
  canvas.addEventListener('click', onCanvasClick);
  document.getElementById('newGame').addEventListener('click', newGame);
  document.getElementById('resultNew').addEventListener('click', newGame);
  document.getElementById('undo').addEventListener('click', undo);
  document.getElementById('resign').addEventListener('click', resign);
  document.getElementById('difficulty').addEventListener('change', function (e) {
    difficulty = e.target.value;
  });

  // 启动
  setupCanvas();
  newGame();
})();
