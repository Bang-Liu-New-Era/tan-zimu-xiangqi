/*
 * xiangqi.js — 中国象棋规则引擎 (Xiangqi rules engine)
 *
 * 棋盘表示 (Board representation):
 *   - 10 行 (row 0..9，0 在顶部=黑方底线，9 在底部=红方底线) × 9 列 (col 0..8，左->右)
 *   - 用 Int8Array(90) 表示，index = row * 9 + col
 *   - 棋子编码: 0=空; 红方 1=K帅 2=A仕 3=E相 4=H马 5=R车 6=C炮 7=P兵
 *             黑方 = 红方 + 8 => 9=K将 10=A士 11=E象 12=H马 13=R车 14=C炮 15=P卒
 *   - color(p): p===0?null : (p<=7 ? 'r' : 'b');  type(p): p<=7?p:(p-8)
 *
 * 该文件同时兼容 Node (module.exports) 与浏览器/Web Worker (globalThis.Xiangqi)。
 */
(function (global) {
  'use strict';

  const RED = 'r', BLACK = 'b';
  const EMPTY = 0;
  // piece codes
  const K = 1, A = 2, E = 3, H = 4, R = 5, C = 6, P = 7;       // red
  const k = 9, a = 10, e = 11, h = 12, r = 13, c = 14, p = 15; // black

  const ROWS = 10, COLS = 9;

  function inBoard(r, c) { return r >= 0 && r < ROWS && c >= 0 && c < COLS; }
  function rc(idx) { return [Math.floor(idx / COLS), idx % COLS]; }
  function idx(r, c) { return r * COLS + c; }

  function colorOf(p) { return p === 0 ? null : (p <= 7 ? RED : BLACK); }
  function typeOf(p) { return p === 0 ? 0 : (p <= 7 ? p : p - 8); }

  function opponent(color) { return color === RED ? BLACK : RED; }

  // 初始局面 (initial position)
  function initialBoard() {
    const b = new Int8Array(90);
    // 黑方 (top, rows 0-2)
    const blackBack = [r, h, e, a, k, a, e, h, r];
    for (let c = 0; c < 9; c++) b[idx(0, c)] = blackBack[c];
    b[idx(2, 1)] = c; b[idx(2, 7)] = c;
    for (let c = 0; c <= 8; c += 2) b[idx(3, c)] = p;
    // 红方 (bottom, rows 7-9)
    const redBack = [R, H, E, A, K, A, E, H, R];
    for (let c = 0; c < 9; c++) b[idx(9, c)] = redBack[c];
    b[idx(7, 1)] = C; b[idx(7, 7)] = C;
    for (let c = 0; c <= 8; c += 2) b[idx(6, c)] = P;
    return b;
  }

  function cloneBoard(b) { return Int8Array.from(b); }

  // 是否在九宫 (palace) 内
  function inPalace(color, r, c) {
    if (c < 3 || c > 5) return false;
    if (color === RED) return r >= 7 && r <= 9;
    return r >= 0 && r <= 2;
  }
  // 象/相 不能过河: 红方只能在 row>=5，黑方只能在 row<=4
  function inElephantHalf(color, r) {
    return color === RED ? r >= 5 : r <= 4;
  }
  // 兵/卒 是否过河
  function crossedRiver(color, r) {
    return color === RED ? r <= 4 : r >= 5;
  }

  // 生成某颜色的伪合法着法 (不含"是否被将"的校验)
  function generatePseudoLegal(b, color) {
    const moves = [];
    for (let i = 0; i < 90; i++) {
      const p = b[i];
      if (p === 0 || colorOf(p) !== color) continue;
      const t = typeOf(p);
      const [r, c] = rc(i);
      switch (t) {
        case K: genKing(b, color, r, c, i, moves); break;
        case A: genAdvisor(b, color, r, c, i, moves); break;
        case E: genElephant(b, color, r, c, i, moves); break;
        case H: genHorse(b, color, r, c, i, moves); break;
        case R: genRook(b, color, r, c, i, moves); break;
        case C: genCannon(b, color, r, c, i, moves); break;
        case P: genPawn(b, color, r, c, i, moves); break;
        default: break;
      }
    }
    return moves;
  }

  function addMove(moves, from, to, b, color) {
    const tp = b[to];
    if (tp !== 0 && colorOf(tp) === color) return; // 不能吃 / 移动到己方棋子
    const capture = tp !== 0;
    moves.push({ from, to, capture, piece: b[from] });
  }

  function genKing(b, color, r, c, i, moves) {
    const dirs = [[-1, 0], [1, 0], [0, -1], [0, 1]];
    for (const [dr, dc] of dirs) {
      const nr = r + dr, nc = c + dc;
      if (!inBoard(nr, nc)) continue;
      if (!inPalace(color, nr, nc)) continue;
      addMove(moves, i, idx(nr, nc), b, color);
    }
  }

  function genAdvisor(b, color, r, c, i, moves) {
    const dirs = [[-1, -1], [-1, 1], [1, -1], [1, 1]];
    for (const [dr, dc] of dirs) {
      const nr = r + dr, nc = c + dc;
      if (!inBoard(nr, nc)) continue;
      if (!inPalace(color, nr, nc)) continue;
      addMove(moves, i, idx(nr, nc), b, color);
    }
  }

  function genElephant(b, color, r, c, i, moves) {
    const dirs = [[-2, -2], [-2, 2], [2, -2], [2, 2]];
    for (const [dr, dc] of dirs) {
      const nr = r + dr, nc = c + dc;
      if (!inBoard(nr, nc)) continue;
      if (!inElephantHalf(color, nr)) continue;
      const er = r + dr / 2, ec = c + dc / 2; // 象眼
      if (b[idx(er, ec)] !== 0) continue;     // 塞象眼
      addMove(moves, i, idx(nr, nc), b, color);
    }
  }

  function genHorse(b, color, r, c, i, moves) {
    // 8 个落点; 每条腿的判别式
    const cand = [
      [-2, -1, -1, 0], [-2, 1, -1, 0],
      [2, -1, 1, 0], [2, 1, 1, 0],
      [-1, -2, 0, -1], [1, -2, 0, -1],
      [-1, 2, 0, 1], [1, 2, 0, 1],
    ];
    for (const [dr, dc, lr, lc] of cand) {
      const nr = r + dr, nc = c + dc;
      if (!inBoard(nr, nc)) continue;
      if (b[idx(r + lr, c + lc)] !== 0) continue; // 蹩马腿
      addMove(moves, i, idx(nr, nc), b, color);
    }
  }

  function genRook(b, color, r, c, i, moves) {
    const dirs = [[-1, 0], [1, 0], [0, -1], [0, 1]];
    for (const [dr, dc] of dirs) {
      let nr = r + dr, nc = c + dc;
      while (inBoard(nr, nc)) {
        const tp = b[idx(nr, nc)];
        if (tp === 0) { moves.push({ from: i, to: idx(nr, nc), capture: false, piece: b[i] }); }
        else {
          if (colorOf(tp) !== color) moves.push({ from: i, to: idx(nr, nc), capture: true, piece: b[i] });
          break;
        }
        nr += dr; nc += dc;
      }
    }
  }

  function genCannon(b, color, r, c, i, moves) {
    const dirs = [[-1, 0], [1, 0], [0, -1], [0, 1]];
    for (const [dr, dc] of dirs) {
      let nr = r + dr, nc = c + dc, screen = false;
      while (inBoard(nr, nc)) {
        const tp = b[idx(nr, nc)];
        if (!screen) {
          if (tp === 0) moves.push({ from: i, to: idx(nr, nc), capture: false, piece: b[i] });
          else screen = true; // 第一个棋子作为炮架
        } else {
          if (tp !== 0) {
            if (colorOf(tp) !== color) moves.push({ from: i, to: idx(nr, nc), capture: true, piece: b[i] });
            break;
          }
        }
        nr += dr; nc += dc;
      }
    }
  }

  function genPawn(b, color, r, c, i, moves) {
    const forward = color === RED ? -1 : 1;
    const nr = r + forward;
    if (inBoard(nr, c)) addMove(moves, i, idx(nr, c), b, color);
    if (crossedRiver(color, r)) {
      if (inBoard(r, c - 1)) addMove(moves, i, idx(r, c - 1), b, color);
      if (inBoard(r, c + 1)) addMove(moves, i, idx(r, c + 1), b, color);
    }
  }

  // 判断 square idx 是否被 byColor 攻击
  function isAttacked(b, target, byColor) {
    const r = Math.floor(target / COLS), c = target % COLS;
    // 车/炮/将 (直线)
    const dirs = [[-1, 0], [1, 0], [0, -1], [0, 1]];
    for (const [dr, dc] of dirs) {
      let nr = r + dr, nc = c + dc, screen = false;
      while (inBoard(nr, nc)) {
        const p = b[idx(nr, nc)];
        if (p !== 0) {
          const pc = colorOf(p), pt = typeOf(p);
          if (!screen) {
            if (pc === byColor) {
              if (pt === R) return true;
              if (pt === K) {
                if (dr !== 0) return true;                 // 同一列: 对面将或相邻
                if (Math.abs(nr - r) + Math.abs(nc - c) === 1) return true; // 横向相邻
              }
            }
            screen = true; // 任何棋子(友/敌)都成为炮架; 也挡住车的后续
          } else {
            if (pc === byColor && pt === C) return true; // 炮翻山
            break;
          }
        }
        nr += dr; nc += dc;
      }
    }
    // 马
    const horse = [[-2, -1], [-2, 1], [2, -1], [2, 1], [-1, -2], [1, -2], [-1, 2], [1, 2]];
    for (const [dr, dc] of horse) {
      const ar = r + dr, ac = c + dc;
      if (!inBoard(ar, ac)) continue;
      const ap = b[idx(ar, ac)];
      if (ap === 0 || colorOf(ap) !== byColor || typeOf(ap) !== H) continue;
      const lr = ar + (Math.abs(dr) === 2 ? dr / 2 : 0);
      const lc = ac + (Math.abs(dc) === 2 ? dc / 2 : 0);
      if (b[idx(lr, lc)] === 0) return true;
    }
    // 兵/卒
    const pawnSrc = [];
    if (byColor === RED) {
      pawnSrc.push([r + 1, c]);
      if (r <= 4) { pawnSrc.push([r, c - 1]); pawnSrc.push([r, c + 1]); }
    } else {
      pawnSrc.push([r - 1, c]);
      if (r >= 5) { pawnSrc.push([r, c - 1]); pawnSrc.push([r, c + 1]); }
    }
    for (const [pr, pc2] of pawnSrc) {
      if (!inBoard(pr, pc2)) continue;
      const p = b[idx(pr, pc2)];
      if (p !== 0 && colorOf(p) === byColor && typeOf(p) === P) return true;
    }
    return false;
  }

  function findKing(b, color) {
    const code = color === RED ? K : k;
    for (let i = 0; i < 90; i++) if (b[i] === code) return i;
    return -1;
  }

  function isInCheck(b, color) {
    const kpos = findKing(b, color);
    if (kpos < 0) return true; // 没有将/帅=已被吃
    return isAttacked(b, kpos, opponent(color));
  }

  // 合法着法 = 伪合法 且 走后不被将 (含"对面将"规则，isAttacked 的将已覆盖)
  function generateLegalMoves(b, color) {
    const pseudo = generatePseudoLegal(b, color);
    const legal = [];
    for (const m of pseudo) {
      const nb = cloneBoard(b);
      nb[m.to] = nb[m.from];
      nb[m.from] = 0;
      if (!isInCheck(nb, color)) legal.push(m);
    }
    return legal;
  }

  function applyMove(b, m) {
    const nb = cloneBoard(b);
    nb[m.to] = nb[m.from];
    nb[m.from] = 0;
    return nb;
  }

  // 简洁 FEN (用于调试 / 外部引擎对接)
  const PIECE_CHAR = { 1: 'K', 2: 'A', 3: 'E', 4: 'H', 5: 'R', 6: 'C', 7: 'P',
    9: 'k', 10: 'a', 11: 'e', 12: 'h', 13: 'r', 14: 'c', 15: 'p' };
  function boardToFen(b, turn) {
    let s = '';
    for (let r = 0; r < ROWS; r++) {
      let empty = 0;
      for (let c = 0; c < COLS; c++) {
        const p = b[idx(r, c)];
        if (p === 0) empty++;
        else { if (empty) { s += empty; empty = 0; } s += PIECE_CHAR[p]; }
      }
      if (empty) s += empty;
      if (r < ROWS - 1) s += '/';
    }
    return s + ' ' + (turn === RED ? 'w' : 'b');
  }

  // UCCI 风格坐标: file = 'a'+col, rank = row (0..9) -> "h2"
  const FILES = 'abcdefghi';
  function sqToUcci(i) { const [r, c] = rc(i); return FILES[c] + r; }
  function moveToUcci(m) { return sqToUcci(m.from) + sqToUcci(m.to); }

  // 局面哈希 (用于重复局面判定 / 置换表)
  function boardHash(b, turn) {
    // 简单字符串键; 在搜索规模下足够
    let s = '';
    for (let i = 0; i < 90; i++) s += b[i].toString(36);
    return s + (turn === RED ? 'r' : 'b');
  }

  // ---- 中文棋谱记谱 (如 "炮八平五") ----
  const HANZI_FILE = ['', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
  const PIECE_NAME = { 1: '帅', 2: '仕', 3: '相', 4: '马', 5: '车', 6: '炮', 7: '兵',
    9: '将', 10: '士', 11: '象', 12: '马', 13: '车', 14: '炮', 15: '卒' };
  // 从走子方视角数路: 红方从右往左 1..9; 黑方从左往右 1..9
  function playerFile(c, color) { return color === RED ? (9 - c) : (c + 1); }
  function moveToNotation(b, m, color) {
    const t = typeOf(m.piece);
    const [r, c] = rc(m.from);
    const [r2, c2] = rc(m.to);
    const name = PIECE_NAME[m.piece];
    const f1 = playerFile(c, color);
    let dir, suffix;
    if (r2 === r) {
      dir = '平';
      suffix = HANZI_FILE[playerFile(c2, color)];
    } else {
      dir = color === RED ? (r2 < r ? '进' : '退') : (r2 > r ? '进' : '退');
      // 马/相/仕走斜线 -> 用目标路; 其余直线棋 -> 用步数
      if (t === H || t === E || t === A) suffix = HANZI_FILE[playerFile(c2, color)];
      else suffix = HANZI_FILE[Math.abs(r2 - r)];
    }
    return name + HANZI_FILE[f1] + dir + suffix;
  }

  const Xiangqi = {
    RED, BLACK, EMPTY, K, A, E, H, R, C, P, k, a, e, h, r, c, p,
    ROWS, COLS,
    inBoard, rc, idx, colorOf, typeOf, opponent,
    initialBoard, cloneBoard,
    inPalace, inElephantHalf, crossedRiver,
    generatePseudoLegal, generateLegalMoves, isAttacked, isInCheck, findKing,
    applyMove, boardToFen, sqToUcci, moveToUcci, boardHash, addMove,
    moveToNotation,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = Xiangqi;
  else global.Xiangqi = Xiangqi;
})(typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : globalThis));
