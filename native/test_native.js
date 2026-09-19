// 用最小 DOM 桩在 Node 中真实加载并运行原生版前端, 验证运行时无崩溃
const vm = require('vm');
const fs = require('fs');
const path = require('path');
const RES = path.join(__dirname, 'Resources');

const ctxStub = new Proxy({}, {
  get: (t, p) => (p in t ? t[p] : () => {}),
  set: () => true,
});

function makeEl(id) {
  const listeners = {};
  const el = {
    id, _listeners: listeners,
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    style: {},
    value: id === 'side' ? 'r' : (id === 'difficulty' ? 'hard' : ''),
    textContent: '', innerHTML: '', scrollTop: 0,
    width: 0, height: 0,
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    appendChild() {},
    getContext() { return ctxStub; },
    getBoundingClientRect() { return { left: 0, top: 0, width: 540, height: 600 }; },
    fire(type, ev) { (listeners[type] || []).forEach(fn => fn(ev)); },
  };
  return el;
}

const els = {};
const document = {
  getElementById(id) { return els[id] || (els[id] = makeEl(id)); },
  createElement() { return makeEl('dyn'); },
};

let rafCount = 0;
const sandbox = {
  window: null, document, console,
  requestAnimationFrame(cb) { rafCount++; /* 不递归, 避免死循环 */ return 1; },
  cancelAnimationFrame() {},
  setTimeout, clearTimeout, setInterval, clearInterval,
  devicePixelRatio: 1,
  Math, Date, JSON, Object, Array, Int8Array, Map, Set, Proxy, Symbol,
  postMessage() {},
};
sandbox.window = sandbox;
sandbox.self = undefined;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

for (const f of ['xiangqi.js', 'ai.js', 'coach.js', 'app.js']) {
  const code = fs.readFileSync(path.join(RES, f), 'utf8');
  vm.runInContext(code, sandbox, { filename: f });
}

const XQ = sandbox.window.XQ;
if (!XQ) throw new Error('window.XQ 未定义 — app.js 启动失败');
console.log('✓ 四个脚本加载成功, XQ 接口存在');

XQ.newGame('r', 'medium');
console.log('✓ newGame 执行, 初始走法记录数 =', els.moveList ? '(moveList 已写)' : '?');

// 模拟玩家点击: 选红马(9,1) 再走 (7,2)
function click(r, c) {
  const ev = { clientX: 30 + c * 60, clientY: 30 + r * 60 };
  els.board.fire('click', ev);
}
click(9, 1); // 选中红马
click(7, 2); // 走马八进七

// 等待 AI 应招 (setTimeout 30ms + 搜索 ~1s)
setTimeout(() => {
  const log = els.moveList.innerHTML;
  console.log('✓ 玩家走子后走法记录含内容:', log.length > 0);
  console.log('  讲解面板文本:', els.commentText.textContent.slice(0, 60));
  console.log('  威胁面板文本:', els.threatText.textContent.slice(0, 40));
  console.log('  评估标签:', els.evalLabel.textContent);
  // 测试提示
  XQ.hint();
  console.log('✓ 提示执行, 提示文本:', els.hintText.textContent.slice(0, 50));
  // 测试悔棋
  XQ.undo();
  console.log('✓ 悔棋执行, 无异常');
  // 测试认输
  XQ.resign();
  console.log('✓ 认输执行, 结果文本:', els.resultText.textContent);
  console.log('\n全部交互路径运行通过，无运行时崩溃 ✔');
  process.exit(0);
}, 2500);
