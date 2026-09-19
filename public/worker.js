// worker.js — 在后台线程运行象棋 AI，避免界面卡顿
importScripts('/engine/xiangqi.js', '/engine/ai.js');

self.onmessage = function (e) {
  const { board, turn, budget, maxDepth } = e.data;
  const b = Int8Array.from(board);
  try {
    const res = self.XiangqiAI.search(b, turn, budget, maxDepth || 8);
    self.postMessage(res);
  } catch (err) {
    self.postMessage({ error: String(err && err.message || err) });
  }
};
