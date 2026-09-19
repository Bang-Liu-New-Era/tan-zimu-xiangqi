/*
 * coach.js — 教学辅助模块 (Xiangqi teaching coach)
 *
 * 挂在 window.Xiangqi.coach 上，依赖 xiangqi.js 与 ai.js。
 * 提供: 提示(hint) / 威胁(threats) / 着法讲解(commentary) /
 *       战术检测(tactics) / 局势评估(evaluate) / 走子质量点评(assessMove)。
 *
 * 这些都不是“规则”，而是给玩家的教学性提示，出错也不影响对局进行。
 */
(function (global) {
  'use strict';
  const X = global.Xiangqi;
  const AI = global.XiangqiAI;
  if (!X || !AI) { console.warn('coach.js: 需要先加载 xiangqi.js 与 ai.js'); return; }

  const { RED, BLACK, EMPTY, colorOf, typeOf, opponent,
    isAttacked, isInCheck, applyMove, generateLegalMoves, findKing, moveToNotation, rc, idx, inBoard } = X;

  const PIECE_NAME = { 1: '帅', 2: '仕', 3: '相', 4: '马', 5: '车', 6: '炮', 7: '兵',
    9: '将', 10: '士', 11: '象', 12: '马', 13: '车', 14: '炮', 15: '卒' };
  const PIECE_VALUE = AI.PIECE_VALUE || { 1: 10000, 2: 200, 3: 200, 4: 400, 5: 900, 6: 450, 7: 100 };

  // 红方视角局势分 (+ 红优 / - 黑优)
  function evaluate(board) { return AI.evaluate(board, RED); }

  // ---- 提示: 返回当前方的最佳着法 + 简短理由 ----
  function hint(board, color, budgetMs) {
    try {
      const res = AI.search(board, color, budgetMs || 1200, 8);
      if (!res || res.from == null) return null;
      return {
        from: res.from, to: res.to,
        score: res.score, depth: res.depth,
        note: hintReason(board, res, color),
      };
    } catch (e) { return null; }
  }
  function hintReason(board, res, color) {
    const before = AI.evaluate(board, color);
    const after = applyMove(board, res);
    const gained = AI.evaluate(after, color) - before;
    if (res.book) return '开局库推荐：控制中心，展开子力。';
    if (Math.abs(res.score) > AI.MATE - 1000) return '可一步将死对方，抓住机会！';
    if (gained > 120) return '这步能白赚一子或夺得主动，值得走。';
    if (gained < -60) return '局面略亏，建议巩固防守。';
    return '稳健的着法，保持局势均衡。';
  }

  // ---- 威胁: 列出 color 方“下一个回合可能被吃且对方能赚子”的棋子 ----
  // 只看对方所有合法着法里“吃我方子”的目标, 且仅当 被吃子价值 >= 攻击子价值
  // (即对方吃掉不会亏) 时才算真正的威胁, 避免把“亏本换子”误报成威胁。
  function threats(board, color) {
    const opp = opponent(color);
    const oppMoves = generateLegalMoves(board, opp); // 一次生成, 高效
    const capMap = new Map(); // sq -> {v, av, name, code}
    for (const m of oppMoves) {
      if (!m.capture) continue;
      const victim = board[m.to];
      if (victim === 0 || colorOf(victim) !== color) continue;
      const v = PIECE_VALUE[typeOf(victim)] || 0;
      const av = PIECE_VALUE[typeOf(board[m.from])] || 0;
      const prev = capMap.get(m.to);
      if (!prev || av < prev.av) capMap.set(m.to, { v, av, name: PIECE_NAME[victim], code: victim });
    }
    const list = [];
    for (const [sq, info] of capMap) {
      if (info.v >= info.av) list.push({ sq, code: info.code, name: info.name, value: info.v });
    }
    list.sort((a, b) => b.value - a.value);
    return { inCheck: isInCheck(board, color), pieces: list };
  }

  // ---- 战术检测 (基于走完一步后的局面) ----
  function tactics(boardAfter, mover, move) {
    const out = [];
    const opp = opponent(mover);
    const ksq = findKing(boardAfter, opp);
    if (ksq < 0) return out;
    const checked = isInCheck(boardAfter, opp);
    if (checked) {
      out.push('将军');
      // 双将: mover 有多少个棋子能攻击对方将/帅 (攻击子数 >= 2)
      const myMoves = generateLegalMoves(boardAfter, mover);
      const nChecks = myMoves.filter(m => m.to === ksq).length;
      if (nChecks >= 2) out.push('双将');
      else {
        const behind = behindPieceName(boardAfter, ksq, mover);
        if (behind) out.push(behind);
      }
    }
    const fc = forkCount(boardAfter, mover);
    if (fc >= 2) out.push('捉双');
    return out;
  }

  // 真正的“捉双/捉”检测: 是否存在某一枚 mover 棋子, 一步能攻击 >=2 个敌子
  function forkCount(boardAfter, mover) {
    const opp = opponent(mover);
    const myMoves = generateLegalMoves(boardAfter, mover);
    const byFrom = new Map();
    for (const m of myMoves) {
      if (!m.capture) continue;
      const victim = boardAfter[m.to];
      if (victim && colorOf(victim) === opp) {
        if (!byFrom.has(m.from)) byFrom.set(m.from, new Set());
        byFrom.get(m.from).add(m.to);
      }
    }
    let best = 0;
    for (const s of byFrom.values()) best = Math.max(best, s.size);
    return best;
  }

  // 判断将线在炮/车翻山之后是否还有同色棋子 -> 命名战术
  function behindPieceName(board, ksq, mover) {
    const [kr, kc] = rc(ksq);
    const dirs = [[-1, 0], [1, 0], [0, -1], [0, 1]];
    for (const [dr, dc] of dirs) {
      let nr = kr + dr, nc = kc + dc, screen = false;
      while (inBoard(nr, nc)) {
        const p = board[idx(nr, nc)];
        if (p === 0) { nr += dr; nc += dc; continue; }
        if (!screen) {
          if (colorOf(p) === mover && typeOf(p) === 6) screen = 'cannon';
          else break;
        } else {
          if (colorOf(p) === mover) {
            const t = typeOf(p);
            if (t === 4) return '马后炮';
            if (t === 5) return '车后炮';
            if (t === 6) return '重炮';
          }
          break;
        }
      }
    }
    return null;
  }

  // mover 走完后, 能“下一步吃掉”的对方棋子列表
  function threatenedOpponent(boardAfter, mover) {
    const opp = opponent(mover);
    const caps = [];
    const moves = generateLegalMoves(boardAfter, mover).filter(m => m.capture);
    for (const m of moves) {
      const victim = boardAfter[m.to];
      if (victim && colorOf(victim) === opp) {
        const v = PIECE_VALUE[typeOf(victim)] || 0;
        const attackerV = PIECE_VALUE[typeOf(boardAfter[m.from])] || 0;
        if (v <= attackerV || v >= 400) caps.push({ sq: m.to, code: victim, value: v });
      }
    }
    const seen = new Set(); const uniq = [];
    for (const c of caps) { if (!seen.has(c.sq)) { seen.add(c.sq); uniq.push(c); } }
    return uniq;
  }

  // ---- 着法讲解 ----
  function commentary(boardBefore, move, boardAfter, mover, ply) {
    const opp = opponent(mover);
    const not = moveToNotation(boardBefore, move, mover);
    const parts = [];
    let captureName = null;
    if (move.capture) {
      const victim = boardBefore[move.to];
      captureName = PIECE_NAME[victim];
      parts.push('吃' + captureName);
    }
    const checked = isInCheck(boardAfter, opp);
    if (checked) parts.push('将军！');
    const open = openingName(ply, move, mover, boardBefore);
    const tx = tactics(boardAfter, mover, move);
    return {
      notation: not,
      capture: !!move.capture,
      captureName,
      check: checked,
      opening: open,
      tactics: tx,
      text: parts.length ? parts.join('，') : '稳健的一步',
    };
  }

  // 开局命名 (仅第 1 步有用)
  function openingName(ply, move, mover, boardBefore) {
    if (ply !== 1) return null;
    const t = typeOf(move.piece);
    const [, c2] = rc(move.to);
    if (t === 6) {
      if (c2 === 4) return '当头炮（中炮）';
      return '过宫炮';
    }
    if (t === 4) return '起马局';
    if (t === 7) return '仙人指路';
    if (t === 3) return '飞相局';
    if (t === 5) return '横车局';
    if (t === 2) return '上仕局';
    return null;
  }

  // ---- 走子质量点评 (教学反馈) ----
  function assessMove(boardBefore, move, mover, budgetMs) {
    try {
      const best = AI.search(boardBefore, mover, budgetMs || 700, 6);
      if (!best || best.from == null) return { quality: 'ok', delta: 0 };
      const bestAfter = applyMove(boardBefore, best);
      const bestScore = AI.evaluate(bestAfter, mover);
      const myAfter = applyMove(boardBefore, move);
      const myScore = AI.evaluate(myAfter, mover);
      const delta = myScore - bestScore;
      let quality = 'ok';
      if (delta <= -250) quality = 'blunder';
      else if (delta <= -90) quality = 'bad';
      else if (delta >= 60) quality = 'good';
      let tip = '';
      if (quality === 'blunder') tip = '这步亏得较多，建议看看提示。';
      else if (quality === 'bad') tip = '这步略亏，还有更好的选择。';
      else if (quality === 'good') tip = '好棋！这步接近最优。';
      return { quality, delta, best: { from: best.from, to: best.to }, tip };
    } catch (e) { return { quality: 'ok', delta: 0 }; }
  }

  const Coach = {
    evaluate, hint, threats, tactics, commentary, openingName,
    assessMove, threatenedOpponent, PIECE_NAME,
  };
  X.coach = Coach;
  if (typeof module !== 'undefined' && module.exports) module.exports = Coach;
})(typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : globalThis));
