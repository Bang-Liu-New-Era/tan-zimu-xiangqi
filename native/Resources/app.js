/* app.js — 教学版前端 (原生 App 内 WebView 运行)
 * 功能: 棋盘绘制/交互 + AI + 教学面板(提示/威胁/讲解/评估/点评) + 特效(粒子/震屏/发光) + 原生桥 */
(function () {
  'use strict';
  const X = window.Xiangqi;
  const AI = window.XiangqiAI;
  const Coach = X.coach;
  const { RED, BLACK, EMPTY } = X;

  const CELL = 60, M = 30;
  const CSSW = 8 * CELL + 2 * M;
  const CSSH = 9 * CELL + 2 * M;

  const PIECE_CHAR = {
    1: '帅', 2: '仕', 3: '相', 4: '马', 5: '车', 6: '炮', 7: '兵',
    9: '将', 10: '士', 11: '象', 12: '马', 13: '车', 14: '炮', 15: '卒'
  };
  const DIFF_BUDGET = { easy: 400, medium: 1000, hard: 1800 };

  // ---------- 状态 ----------
  let board, turn, humanColor, selected, legalTargets;
  let history, lastMove, over, repCount, moveLog;
  let aiThinking = false, difficulty = 'hard', teaching = true;
  let redTime = 0, blackTime = 0, turnTimerStart = 0;
  let worker = null, thinkingRAF = 0, thinkingStart = 0;

  // 特效状态
  let capFx = null;          // 吃子圆环 {sq,start}
  let particles = [];        // 粒子数组
  let shake = 0;             // 震屏强度
  let hintMove = null;       // 提示高亮 {from,to,start}
  let threatSqs = [];        // 受威胁格数组
  let flashRed = 0;          // 红闪强度 (将军)

  // ---------- DOM ----------
  const canvas = document.getElementById('board');
  const ctx = canvas.getContext('2d');
  const statusEl = document.getElementById('status');
  const redTimeEl = document.getElementById('redTime');
  const blackTimeEl = document.getElementById('blackTime');
  const moveListEl = document.getElementById('moveList');
  const resultEl = document.getElementById('result');
  const resultTextEl = document.getElementById('resultText');
  const evalLabel = document.getElementById('evalLabel');
  const evalRed = document.getElementById('evalRed');
  const threatText = document.getElementById('threatText');
  const commentText = document.getElementById('commentText');
  const hintBox = document.getElementById('hintBox');
  const hintText = document.getElementById('hintText');
  const assessBox = document.getElementById('assessBox');
  const assessText = document.getElementById('assessText');

  function postNative(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.xiangqi) {
        window.webkit.messageHandlers.xiangqi.postMessage(msg);
      }
    } catch (e) {}
  }

  function setupCanvas() {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = CSSW * dpr; canvas.height = CSSH * dpr;
    canvas.style.width = CSSW + 'px'; canvas.style.height = CSSH + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
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
  function render() {
    ctx.save();
    if (shake > 0.01) {
      const dx = (Math.random() - 0.5) * 10 * shake;
      const dy = (Math.random() - 0.5) * 10 * shake;
      ctx.translate(dx, dy);
      shake *= 0.86;
    }
    drawBoardBase();
    drawHighlights();
    for (let r = 0; r < 10; r++)
      for (let c = 0; c < 9; c++) {
        const p = board[X.idx(r, c)];
        if (p !== EMPTY) drawPiece(r, c, p);
      }
    drawParticles();
    if (flashRed > 0.01) {
      ctx.fillStyle = 'rgba(214,69,49,' + (flashRed * 0.35).toFixed(3) + ')';
      ctx.fillRect(-20, -20, CSSW + 40, CSSH + 40);
      flashRed *= 0.9;
    }
    ctx.restore();
    requestAnimationFrame(render);
  }

  function drawBoardBase() {
    ctx.clearRect(-30, -30, CSSW + 60, CSSH + 60);
    ctx.fillStyle = '#e8b974';
    ctx.fillRect(0, 0, CSSW, CSSH);
    ctx.strokeStyle = '#5a3a1a'; ctx.lineWidth = 1.4;
    for (let r = 0; r < 10; r++) { ctx.beginPath(); ctx.moveTo(cx(0), cy(r)); ctx.lineTo(cx(8), cy(r)); ctx.stroke(); }
    for (let c = 0; c < 9; c++) {
      if (c === 0 || c === 8) { ctx.beginPath(); ctx.moveTo(cx(c), cy(0)); ctx.lineTo(cx(c), cy(9)); ctx.stroke(); }
      else {
        ctx.beginPath(); ctx.moveTo(cx(c), cy(0)); ctx.lineTo(cx(c), cy(4)); ctx.stroke();
        ctx.beginPath(); ctx.moveTo(cx(c), cy(5)); ctx.lineTo(cx(c), cy(9)); ctx.stroke();
      }
    }
    drawPalace(0, 2); drawPalace(7, 9);
    ctx.fillStyle = '#7a4a1a';
    ctx.font = '22px "KaiTi","STKaiti",serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText('楚　河', cx(1.5), cy(4.5));
    ctx.fillText('漢　界', cx(6.5), cy(4.5));
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
      drawArrow(lastMove.from, lastMove.to);
    }
    if (selected !== null) {
      const [r, c] = X.rc(selected);
      ctx.strokeStyle = '#f1c40f'; ctx.lineWidth = 3;
      ctx.strokeRect(cx(c) - CELL / 2 + 2, cy(r) - CELL / 2 + 2, CELL - 4, CELL - 4);
    }
    if (legalTargets) {
      for (const t of legalTargets) {
        const [r, c] = X.rc(t);
        const occupied = board[t] !== EMPTY;
        if (occupied) {
          ctx.beginPath(); ctx.arc(cx(c), cy(r), CELL * 0.42, 0, Math.PI * 2);
          ctx.strokeStyle = 'rgba(192,57,43,0.9)'; ctx.lineWidth = 3; ctx.stroke();
        } else {
          ctx.fillStyle = 'rgba(192,57,43,0.85)';
          ctx.beginPath(); ctx.arc(cx(c), cy(r), 7, 0, Math.PI * 2); ctx.fill();
        }
      }
    }
    // 提示高亮 (发光脉冲)
    if (hintMove) {
      const dt = (Date.now() - hintMove.start) / 600;
      const pulse = 0.5 + 0.5 * Math.sin(Date.now() / 180);
      const a = 0.5 + 0.4 * pulse;
      for (const sq of [hintMove.from, hintMove.to]) {
        const [r, c] = X.rc(sq);
        ctx.save();
        ctx.strokeStyle = 'rgba(255,207,107,' + a.toFixed(2) + ')';
        ctx.lineWidth = 4;
        ctx.shadowColor = 'rgba(255,207,107,0.9)'; ctx.shadowBlur = 14 * pulse;
        ctx.beginPath(); ctx.arc(cx(c), cy(r), CELL * 0.44, 0, Math.PI * 2); ctx.stroke();
        ctx.restore();
      }
    }
    // 受威胁子 (红色脉冲圈)
    if (teaching) {
      const pulse = 0.5 + 0.5 * Math.sin(Date.now() / 220);
      for (const sq of threatSqs) {
        const [r, c] = X.rc(sq);
        ctx.save();
        ctx.strokeStyle = 'rgba(231,76,60,' + (0.45 + 0.4 * pulse).toFixed(2) + ')';
        ctx.lineWidth = 3;
        ctx.beginPath(); ctx.arc(cx(c), cy(r), CELL * 0.46, 0, Math.PI * 2); ctx.stroke();
        ctx.restore();
      }
    }
    // 吃子圆环
    if (capFx) {
      const dt = Date.now() - capFx.start;
      if (dt < 600) {
        const [r, c] = X.rc(capFx.sq);
        const p = dt / 600;
        const rad = CELL * 0.18 + p * CELL * 0.42;
        ctx.save();
        ctx.strokeStyle = 'rgba(214,69,49,' + (1 - p).toFixed(2) + ')';
        ctx.lineWidth = 5;
        ctx.beginPath(); ctx.arc(cx(c), cy(r), rad, 0, Math.PI * 2); ctx.stroke();
        ctx.fillStyle = 'rgba(214,69,49,' + (1 - p).toFixed(2) + ')';
        ctx.font = 'bold 22px "KaiTi","STKaiti",serif';
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText('吃', cx(c), cy(r) - CELL * 0.62);
        ctx.restore();
      } else capFx = null;
    }
  }

  function drawArrow(from, to) {
    const [r1, c1] = X.rc(from), [r2, c2] = X.rc(to);
    const x1 = cx(c1), y1 = cy(r1), x2 = cx(c2), y2 = cy(r2);
    ctx.save();
    ctx.strokeStyle = 'rgba(30,110,90,0.95)'; ctx.fillStyle = 'rgba(30,110,90,0.95)';
    ctx.lineWidth = 4; ctx.lineCap = 'round';
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    const ang = Math.atan2(y2 - y1, x2 - x1), len = 16;
    ctx.beginPath();
    ctx.moveTo(x2, y2);
    ctx.lineTo(x2 - len * Math.cos(ang - 0.5), y2 - len * Math.sin(ang - 0.5));
    ctx.lineTo(x2 - len * Math.cos(ang + 0.5), y2 - len * Math.sin(ang + 0.5));
    ctx.closePath(); ctx.fill();
    ctx.restore();
  }

  function drawPiece(r, c, code) {
    const x = cx(c), y = cy(r), rad = CELL * 0.40;
    ctx.beginPath(); ctx.arc(x, y, rad, 0, Math.PI * 2);
    ctx.fillStyle = '#f7eccb'; ctx.fill();
    ctx.lineWidth = 2; ctx.strokeStyle = X.colorOf(code) === RED ? '#c0392b' : '#2b2b2b'; ctx.stroke();
    ctx.fillStyle = X.colorOf(code) === RED ? '#c0392b' : '#2b2b2b';
    ctx.font = 'bold 30px "KaiTi","STKaiti","PingFang SC",serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(PIECE_CHAR[code], x, y + 1);
  }

  function drawParticles() {
    if (!particles.length) return;
    for (let i = particles.length - 1; i >= 0; i--) {
      const p = particles[i];
      p.x += p.vx; p.y += p.vy; p.vy += 0.12; p.life -= 0.03;
      if (p.life <= 0) { particles.splice(i, 1); continue; }
      ctx.save();
      ctx.globalAlpha = Math.max(0, p.life);
      ctx.fillStyle = p.color;
      ctx.beginPath(); ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2); ctx.fill();
      ctx.restore();
    }
  }
  function spawnParticles(sq, color) {
    const [r, c] = X.rc(sq); const x = cx(c), y = cy(r);
    for (let i = 0; i < 16; i++) {
      const a = Math.random() * Math.PI * 2, sp = 1.4 + Math.random() * 3.2;
      particles.push({ x, y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp - 1, life: 1, color, size: 2 + Math.random() * 2.5 });
    }
  }

  // ---------- 交互 ----------
  function onCanvasClick(ev) {
    if (over || aiThinking) return;
    if (turn !== humanColor) return;
    const rc = eventToRC(ev); if (!rc) return;
    const i = X.idx(rc.r, rc.c);
    postNative({ type: 'sound', name: 'click' });
    if (selected === null) {
      if (board[i] !== EMPTY && X.colorOf(board[i]) === humanColor) {
        selected = i;
        legalTargets = X.generateLegalMoves(board, humanColor).filter(m => m.from === i).map(m => m.to);
        drawBoard();
      }
      return;
    }
    if (i === selected) { clearSelection(); return; }
    if (board[i] !== EMPTY && X.colorOf(board[i]) === humanColor) {
      selected = i;
      legalTargets = X.generateLegalMoves(board, humanColor).filter(m => m.from === i).map(m => m.to);
      return;
    }
    if (legalTargets.includes(i)) {
      doMove({ from: selected, to: i, piece: board[selected], capture: board[i] !== EMPTY }, humanColor);
    }
    clearSelection();
  }
  function clearSelection() { selected = null; legalTargets = null; }
  function drawBoard() { /* render 循环已持续重绘, 这里留空以避免重复 */ }

  // ---------- 走子 ----------
  function snapshot() {
    return { board: Int8Array.from(board), turn, humanColor, lastMove, over,
      repCount: Object.assign({}, repCount), redTime, blackTime, moveLog: moveLog.slice() };
  }
  function doMove(move, mover) {
    history.push(snapshot());
    const dt = Date.now() - turnTimerStart;
    if (mover === RED) redTime += dt; else blackTime += dt;

    const text = X.moveToNotation(board, move, mover);
    moveLog.push({ color: mover, text });

    board = X.applyMove(board, move);
    lastMove = { from: move.from, to: move.to };
    const isCap = move.capture;
    if (isCap) { capFx = { sq: move.to, start: Date.now() }; spawnParticles(move.to, '#d64931'); postNative({ type: 'sound', name: 'capture' }); }
    else postNative({ type: 'sound', name: 'move' });

    turn = X.opponent(mover);
    const key = X.boardHash(board, turn);
    repCount[key] = (repCount[key] || 0) + 1;

    updateTimers(); renderMoveLog(); updateCoach(move, mover);

    if (repCount[key] >= 3) { endGame('draw', '和棋（三次重复局面）'); return; }

    const moves = X.generateLegalMoves(board, turn);
    if (moves.length === 0) {
      const chk = X.isInCheck(board, turn);
      const winner = X.opponent(turn);
      endGame(winner === RED ? 'red' : 'black', (winner === RED ? '红方' : '黑方') + '胜（' + (chk ? '将死' : '困毙') + '）');
      return;
    }
    // 将军特效
    if (X.isInCheck(board, turn)) {
      shake = 1; flashRed = 1; postNative({ type: 'sound', name: 'check' });
    }
    updateStatus();
    if (turn !== humanColor) startAI();
    else turnTimerStart = Date.now();
  }

  // ---------- 教学面板 ----------
  function updateCoach(move, mover) {
    if (!move) {
      // 仅刷新评估条与威胁 (开局/悔棋后)
      const ev = Coach.evaluate(board);
      const pct = Math.max(2, Math.min(98, 50 + ev / 40));
      evalRed.style.width = pct + '%';
      if (Math.abs(ev) < 60) evalLabel.textContent = '均势';
      else if (ev > 0) evalLabel.textContent = '红优 +' + Math.round(ev);
      else evalLabel.textContent = '黑优 ' + Math.round(ev);
      const th = Coach.threats(board, turn);
      threatSqs = th.pieces.map(p => p.sq);
      threatText.textContent = th.pieces.length ? ((turn === humanColor ? '你的 ' : '电脑的 ') + th.pieces.map(p => p.name).join('、') + ' 受到威胁') : '暂无威胁';
      threatText.classList.toggle('warn', th.pieces.length > 0);
      return;
    }
    // 讲解
    const cm = Coach.commentary(boardBeforeSnapFor(mover), move, board, mover, moveLog.length);
    let txt = cm.notation + (mover === RED ? '（红）' : '（黑）');
    const bits = [];
    if (cm.opening) bits.push(cm.opening);
    if (cm.tactics.length) bits.push(cm.tactics.join('、'));
    if (cm.text && cm.text !== '稳健的一步') bits.push(cm.text);
    if (bits.length) txt += ' — ' + bits.join('，');
    commentText.textContent = txt;

    // 评估条
    const ev = Coach.evaluate(board); // 红视角
    const pct = Math.max(2, Math.min(98, 50 + ev / 40));
    evalRed.style.width = pct + '%';
    if (Math.abs(ev) < 60) evalLabel.textContent = '均势';
    else if (ev > 0) evalLabel.textContent = '红优 +' + Math.round(ev);
    else evalLabel.textContent = '黑优 ' + Math.round(ev);

    // 当前走子方威胁
    const th = Coach.threats(board, turn);
    threatSqs = th.pieces.map(p => p.sq);
    if (th.inCheck) {
      threatText.textContent = (turn === humanColor ? '你被将军！' : '电脑被将军！') + ' 速速应将';
      threatText.classList.add('warn');
    } else if (th.pieces.length) {
      threatText.textContent = (turn === humanColor ? '你的 ' : '电脑的 ') +
        th.pieces.map(p => p.name).join('、') + ' 受到威胁';
      threatText.classList.add('warn');
    } else {
      threatText.textContent = '暂无威胁';
      threatText.classList.remove('warn');
    }

    // 人类走子质量点评
    if (mover === humanColor && move) {
      const a = Coach.assessMove(boardBeforeSnapFor(mover), move, mover, 500);
      if (a.quality !== 'ok') {
        assessBox.classList.remove('hidden');
        assessText.textContent = a.tip;
        assessText.className = 'coach-c ' + a.quality;
      } else { assessBox.classList.add('hidden'); }
    }
  }
  // 走子前的局面 (用于点评/讲解): 用 history 最后一项
  function boardBeforeSnapFor(mover) {
    if (history.length) return Int8Array.from(history[history.length - 1].board);
    return board;
  }

  // ---------- AI ----------
  // 原生 App 内直接在主线程计算(界面有原生外壳, 短暂思考不阻塞窗口交互感)
  function startAI() {
    if (over) return;
    aiThinking = true;
    thinkingStart = Date.now();
    updateStatus();
    tickThinking();
    scheduleSyncAI();
  }
  function tickThinking() {
    const el = (Date.now() - thinkingStart) / 1000;
    statusEl.innerHTML = '轮到 <b>' + (turn === RED ? '红方' : '黑方') + '</b>（电脑）走棋 · 思考 ' + el.toFixed(1) + 's';
    thinkingRAF = requestAnimationFrame(tickThinking);
  }
  function scheduleSyncAI() {
    setTimeout(function () {
      let res = null;
      try { res = AI.search(Int8Array.from(board), turn, DIFF_BUDGET[difficulty], 8); }
      catch (err) { res = null; }
      onWorkerResult({ data: res });
    }, 30);
  }
  function onWorkerResult(e) {
    cancelAnimationFrame(thinkingRAF);
    aiThinking = false;
    const res = e.data;
    let move = null;
    if (res && res.from !== undefined) {
      move = { from: res.from, to: res.to, piece: board[res.from], capture: board[res.to] !== EMPTY };
    }
    if (!move || !X.generateLegalMoves(board, turn).some(m => m.from === move.from && m.to === move.to)) {
      const legal = X.generateLegalMoves(board, turn);
      if (legal.length) move = legal[0];
    }
    if (!move) { updateStatus(); return; }
    doMove(move, turn);
  }

  // ---------- 控件 / 原生接口 ----------
  function newGame() {
    board = X.initialBoard();
    turn = RED;
    humanColor = document.getElementById('side').value === 'b' ? BLACK : RED;
    selected = null; legalTargets = null;
    history = []; lastMove = null; over = false;
    repCount = {}; moveLog = [];
    redTime = 0; blackTime = 0;
    particles = []; capFx = null; hintMove = null; threatSqs = []; shake = 0; flashRed = 0;
    resultEl.classList.add('hidden');
    commentText.textContent = '开局！' + (humanColor === RED ? '你执红先走。' : '你执黑，电脑（红）先走。');
    assessBox.classList.add('hidden');
    renderMoveLog(); updateTimers(); updateCoach(null, RED);
    updateStatus();
    if (humanColor === BLACK) startAI();
    else turnTimerStart = Date.now();
  }
  function undo() {
    if (aiThinking) return;
    let pops = 0;
    while (history.length && pops < 2) {
      const snap = history.pop();
      board = Int8Array.from(snap.board);
      turn = snap.turn; humanColor = snap.humanColor; lastMove = snap.lastMove;
      over = snap.over; repCount = Object.assign({}, snap.repCount);
      redTime = snap.redTime; blackTime = snap.blackTime; moveLog = snap.moveLog.slice();
      pops++;
      if (turn === humanColor) break;
    }
    if (!history.length && !pops) return;
    over = false; hintMove = null; threatSqs = [];
    resultEl.classList.add('hidden');
    renderMoveLog(); updateTimers(); updateCoach(null, turn); updateStatus();
    turnTimerStart = Date.now();
  }
  function resign() {
    if (over) return;
    const loser = humanColor;
    endGame(loser === RED ? 'black' : 'red', (loser === RED ? '黑方' : '红方') + '胜（你认输）');
  }
  function hint() {
    if (over || aiThinking || turn !== humanColor) return;
    const h = Coach.hint(board, humanColor, 1200);
    if (!h) return;
    hintMove = { from: h.from, to: h.to, start: Date.now() };
    hintBox.classList.remove('hidden');
    hintText.textContent = '建议：' + X.moveToNotation(board, { from: h.from, to: h.to, piece: board[h.from] }, humanColor)
      + '。' + h.note;
  }
  function endGame(result, text) {
    over = true; aiThinking = false;
    cancelAnimationFrame(thinkingRAF);
    resultTextEl.textContent = text;
    resultEl.classList.remove('hidden');
    updateStatus();
    postNative({ type: 'gameover', result, reason: text });
    if (result === 'draw') postNative({ type: 'sound', name: 'lose' });
    else if (result === (humanColor === RED ? 'red' : 'black')) postNative({ type: 'sound', name: 'win' });
    else postNative({ type: 'sound', name: 'lose' });
  }
  function updateStatus() {
    if (over) return;
    const who = turn === RED ? '红方' : '黑方';
    const tag = turn === humanColor ? '（你）' : '（电脑）';
    statusEl.innerHTML = '轮到 <b>' + who + '</b>' + tag + ' 走棋' + (aiThinking ? ' · 思考中' : '');
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

  // ---------- 暴露给原生工具栏 ----------
  window.XQ = {
    newGame: function (side, diff) {
      if (side) document.getElementById('side').value = side;
      if (diff) document.getElementById('difficulty').value = diff;
      difficulty = diff || difficulty;
      newGame();
    },
    undo: undo,
    resign: resign,
    hint: hint,
    setDifficulty: function (d) { difficulty = d; document.getElementById('difficulty').value = d; },
    setTeaching: function (on) { teaching = !!on; document.body.classList.toggle('no-coach', !on); },
    state: function () { return { over, turn, humanColor, aiThinking }; }
  };

  // ---------- 绑定 ----------
  document.getElementById('side').addEventListener('change', newGame);
  document.getElementById('difficulty').addEventListener('change', function (e) { difficulty = e.target.value; });
  canvas.addEventListener('click', onCanvasClick);
  document.getElementById('newGame').addEventListener('click', newGame);
  document.getElementById('resultNew').addEventListener('click', newGame);
  document.getElementById('undo').addEventListener('click', undo);
  document.getElementById('resign').addEventListener('click', resign);
  document.getElementById('hint').addEventListener('click', hint);

  // ---------- 启动 ----------
  setupCanvas();
  postNative({ type: 'ready' });
  newGame();
  requestAnimationFrame(render);
})();
