/*
 * ai.js — 中国象棋 AI (alpha-beta 搜索引擎)
 *
 * 特性:
 *   - Negamax + Alpha-Beta 剪枝
 *   - 迭代加深 (iterative deepening)，受"时间预算"硬约束 -> 保证每步 ≤ 预算
 *   - 静态搜索 (quiescence) 处理吃子，避免水平线效应
 *   - 置换表 (transposition table) 提速
 *   - 简单开局库 (开局第一步走当头炮)
 *   - 走法排序 (MVV-LVA + 置换表首选)
 *
 * 与 xiangqi.js 共享棋盘表示 (Int8Array(90))。
 */
(function (global) {
  'use strict';
  const X = (typeof require !== 'undefined') ? require('./xiangqi.js') : global.Xiangqi;
  const { RED, BLACK, EMPTY, K, A, E, H, R, C, P, ROWS, COLS,
    colorOf, typeOf, opponent, inBoard, rc, idx,
    initialBoard, cloneBoard, generateLegalMoves, applyMove, boardHash, findKing } = X;

  const MATE = 100000;
  const PIECE_VALUE = { 1: 10000, 2: 200, 3: 200, 4: 400, 5: 900, 6: 450, 7: 100 };

  // ---- 评估 (从走子方视角返回分数) ----
  function evaluate(b, turn) {
    let score = 0;
    for (let i = 0; i < 90; i++) {
      const p = b[i];
      if (p === 0) continue;
      const col = colorOf(p), t = typeOf(p);
      let v = PIECE_VALUE[t];
      const r = (i / COLS) | 0, c = i % COLS;
      if (t === P) {
        const adv = col === RED ? (9 - r) : r;
        v += adv * 8 + (X.crossedRiver(col, r) ? 25 : 0);
      } else if (t === H) {
        v -= Math.abs(c - 4) * 8;
      } else if (t === C) {
        v -= Math.abs(c - 4) * 4;
      } else if (t === R) {
        v -= Math.abs(c - 4) * 3;
      } else if (t === E || t === A) {
        v -= Math.abs(c - 4) * 4;
      }
      score += (col === RED) ? v : -v;
    }
    return turn === RED ? score : -score;
  }

  // ---- 置换表 ----
  const tt = new Map();
  const TT_SIZE = 200000;

  function probeTT(key, depth, alpha, beta) {
    const e = tt.get(key);
    if (!e || e.depth < depth) return null;
    if (e.flag === 0) return { score: e.score, move: e.move }; // EXACT
    if (e.flag === 1 && e.score >= beta) return { score: e.score, move: e.move }; // LOWER
    if (e.flag === 2 && e.score <= alpha) return { score: e.score, move: e.move }; // UPPER
    return null;
  }
  function storeTT(key, depth, score, flag, move) {
    if (tt.size > TT_SIZE) tt.clear();
    tt.set(key, { depth, score, flag, move });
  }

  // ---- 走法排序 (MVV-LVA: 先吃大子、用小子吃) ----
  function orderMoves(b, moves, ttMove) {
    moves.sort((a, b2) => {
      if (ttMove && a.from === ttMove.from && a.to === ttMove.to) return -1;
      if (ttMove && b2.from === ttMove.from && b2.to === ttMove.to) return 1;
      const av = a.capture ? (PIECE_VALUE[typeOf(b[a.to])] * 10 - PIECE_VALUE[typeOf(a.piece)]) : -1;
      const bv = b2.capture ? (PIECE_VALUE[typeOf(b[b2.to])] * 10 - PIECE_VALUE[typeOf(b2.piece)]) : -1;
      return bv - av;
    });
  }

  // ---- 搜索状态 ----
  const ABORT = Symbol('abort');
  let aborted = false, nodeCount = 0, startTime = 0, budget = 0;

  function quiesce(b, turn, alpha, beta, ply) {
    if (aborted) throw ABORT;
    const stand = evaluate(b, turn);
    if (stand >= beta) return beta;
    if (stand > alpha) alpha = stand;
    const moves = generateLegalMoves(b, turn).filter(m => m.capture);
    orderMoves(b, moves, null);
    for (const m of moves) {
      const nb = applyMove(b, m);
      const score = -quiesce(nb, opponent(turn), -beta, -alpha, ply + 1);
      if (score >= beta) return beta;
      if (score > alpha) alpha = score;
    }
    return alpha;
  }

  function negamax(b, turn, depth, alpha, beta, ply) {
    if (aborted) throw ABORT;
    if ((++nodeCount & 2047) === 0 && Date.now() - startTime > budget) { aborted = true; throw ABORT; }

    const key = boardHash(b, turn);
    const ttProbe = probeTT(key, depth, alpha, beta);
    if (ttProbe) return ttProbe.score;

    const moves = generateLegalMoves(b, turn);
    if (moves.length === 0) {
      // 无合法着法: 被将死或困毙 (均判负)
      return -MATE + ply;
    }
    if (depth <= 0) return quiesce(b, turn, alpha, beta, ply);

    let ttMove = null;
    const e = tt.get(key);
    if (e) ttMove = e.move;

    orderMoves(b, moves, ttMove);

    let best = -Infinity, bestMove = moves[0];
    let flag = 2; // UPPER
    for (const m of moves) {
      const nb = applyMove(b, m);
      const score = -negamax(nb, opponent(turn), depth - 1, -beta, -alpha, ply + 1);
      if (score > best) { best = score; bestMove = m; }
      if (best > alpha) { alpha = best; flag = 0; } // EXACT (tentative)
      if (alpha >= beta) { flag = 1; break; }        // LOWER
    }
    storeTT(key, depth, best, flag, bestMove);
    return best;
  }

  // ---- 开局库 ----
  let _initialHash = null;
  function initialHash() {
    if (_initialHash === null) _initialHash = boardHash(initialBoard(), RED);
    return _initialHash;
  }
  function bookMove(b, turn) {
    if (boardHash(b, turn) === initialHash() && turn === RED) {
      // 当头炮: 红炮 (7,1) -> (7,4)
      return { from: idx(7, 1), to: idx(7, 4) };
    }
    return null;
  }

  // ---- 对外接口 ----
  function search(board, turn, budgetMs, maxDepth) {
    budget = budgetMs; startTime = Date.now(); aborted = false; nodeCount = 0;
    maxDepth = maxDepth || 7;

    const bk = bookMove(board, turn);
    if (bk) return { from: bk.from, to: bk.to, score: 0, depth: 0, nodes: 0, timeMs: Date.now() - startTime, book: true };

    let bestMove = null, bestScore = 0, completedDepth = 0;
    for (let d = 1; d <= maxDepth; d++) {
      try {
        const score = negamax(board, turn, d, -Infinity, Infinity, 0);
        // 取该深度首选着法
        const key = boardHash(board, turn);
        const e = tt.get(key);
        const bm = e ? e.move : null;
        if (bm) { bestMove = bm; bestScore = score; completedDepth = d; }
        if (Math.abs(score) > MATE - 1000) break; // 已找到杀棋
      } catch (err) {
        if (err === ABORT) break;
        throw err;
      }
      if (Date.now() - startTime > budget) break;
    }
    if (!bestMove) {
      // 兜底: 任意合法着法
      const moves = generateLegalMoves(board, turn);
      if (moves.length) bestMove = moves[0];
    }
    return {
      from: bestMove.from, to: bestMove.to,
      score: bestScore, depth: completedDepth,
      nodes: nodeCount, timeMs: Date.now() - startTime,
    };
  }

  const XiangqiAI = { search, evaluate, PIECE_VALUE, MATE, clearTT: () => tt.clear() };
  if (typeof module !== 'undefined' && module.exports) module.exports = XiangqiAI;
  else global.XiangqiAI = XiangqiAI;
})(typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : globalThis));
