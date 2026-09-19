const X = require('./engine/xiangqi.js');
const AI = require('./engine/ai.js');

function legalMove(b, color, m) {
  const moves = X.generateLegalMoves(b, color);
  return moves.some(x => x.from === m.from && x.to === m.to);
}

// 1) 飞行将帅规则: 红帅(9,4)与黑将(0,4)之间只有红车(5,4)遮挡，
//    红车若离开第4列(被将)，则红帅与黑将照面 -> 该走法非法
(() => {
  const b = X.initialBoard();
  // 清空棋盘，只留双方将/帅 + 中间一个红车
  const empty = new Int8Array(90);
  empty[X.idx(9, 4)] = X.K;   // 红帅
  empty[X.idx(0, 4)] = X.k;   // 黑将
  empty[X.idx(5, 4)] = X.R;   // 红车在中间遮挡
  const moves = X.generateLegalMoves(empty, X.RED);
  const rookMoves = moves.filter(m => m.from === X.idx(5, 4));
  const offFile = rookMoves.filter(m => (X.rc(m.to)[1]) !== 4);
  const onFile = rookMoves.filter(m => (X.rc(m.to)[1]) === 4);
  console.log('[飞行将] 红车合法着法: 留在第4列=', onFile.length, ' 离开第4列=', offFile.length, '(应为0)');
  if (offFile.length !== 0) throw new Error('飞行将规则未生效!');
})();

// 2) 计时: 每步必须在预算内返回，且着法合法
(() => {
  const BUDGET = 2500;
  let b = X.initialBoard();
  let turn = X.RED;
  let maxTime = 0, total = 0;
  const N = 8;
  for (let i = 0; i < N; i++) {
    const t0 = Date.now();
    const mv = AI.search(b, turn, BUDGET, 7);
    const dt = Date.now() - t0;
    if (!mv || !legalMove(b, turn, mv)) throw new Error('返回非法着法 @ply ' + i);
    maxTime = Math.max(maxTime, dt);
    total += dt;
    b = X.applyMove(b, mv);
    turn = X.opponent(turn);
  }
  console.log(`[计时] ${N}步, 最大耗时=${maxTime}ms, 平均=${(total / N).toFixed(0)}ms, 预算=${BUDGET}ms -> 满足≤3s:`, maxTime <= 3000);
})();

// 3) 自对弈: 红黑AI互搏，验证全程合法，并在出现终局时停止
(() => {
  let b = X.initialBoard();
  let turn = X.RED;
  let plies = 0, ended = false;
  const seen = new Map();
  const DEADLINE = Date.now() + 90000; // 整体不超过 90s
  for (; plies < 60; plies++) {
    if (Date.now() > DEADLINE) break;
    // 重复局面检测(3次和棋)
    const key = X.boardHash(b, turn);
    seen.set(key, (seen.get(key) || 0) + 1);
    if (seen.get(key) >= 3) { console.log('[自对弈] 三次重复 -> 和棋'); ended = true; break; }

    const mv = AI.search(b, turn, 600, 6);
    if (!mv || !legalMove(b, turn, mv)) throw new Error('自对弈非法着法 @ply ' + plies);
    b = X.applyMove(b, mv);
    // 终局检测
    const moves = X.generateLegalMoves(b, X.opponent(turn));
    if (moves.length === 0) {
      const inChk = X.isInCheck(b, X.opponent(turn));
      console.log(`[自对弈] ${plies + 1}步后终局: ${inChk ? '将死' : '困毙'} (${X.opponent(turn) === X.RED ? '红' : '黑'}方负)`);
      ended = true; break;
    }
    turn = X.opponent(turn);
  }
  if (!ended) console.log('[自对弈] 达到步数上限未分胜负 (平推)', plies, '步');
  console.log('[自对弈] 完成', plies, '步无崩溃/无非法着法 ✔');
})();

console.log('\n全部测试通过 ✔');
