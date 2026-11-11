const { JSDOM } = require('jsdom');
const fs = require('fs');
const GATE = fs.readFileSync(process.argv[2] + '/js/gate.js', 'utf8');
function run(html, url, size) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  w.HTMLElement.prototype.getBoundingClientRect = function(){ const s = this.getAttribute('data-size'); const n = s ? +s : (size||300); return {width:n,height:n}; };
  Object.defineProperty(w.HTMLElement.prototype, 'innerText', { get(){ return this.textContent; } });
  const msgs = [];
  w.webkit = { messageHandlers: { df: { postMessage(m){ msgs.push(m); return Promise.resolve(); } } } };
  w.eval(GATE);
  return { w, msgs };
}
let ok = true; const check=(c,m)=>{console.log((c?'PASS ':'FAIL ')+m); if(!c) ok=false;};
const k = t => t.msgs.map(m=>m.kind).join(',');
check(k(run('<h1>Box Logo Tee</h1>', 'https://kr.supreme.com/products/x'))==='none', 'product page → none');
check(k(run('<h1>You are now in line</h1>', 'https://kr-supreme.queue-it.net/?c=x&e=y'))==='queue', 'queue-it host');
check(k(run('<p>x</p>', 'https://shop-kr.palaceskateboards.com/throttle/queue'))==='queue', 'shopify throttle queue path');
check(k(run('<title>접속 대기 안내</title><h2>현재 대기열에 계십니다</h2>', 'https://kr.supreme.com/'))==='queue', 'korean queue text');
check(k(run('<iframe src="https://newassets.hcaptcha.com/captcha/v1/x"></iframe>', 'https://kr.supreme.com/checkouts/cn/x'))==='captcha', 'hcaptcha iframe');
check(k(run('<iframe data-size="0" src="https://www.google.com/recaptcha/api2/anchor?size=invisible"></iframe><h1>상품</h1>', 'https://kr.supreme.com/'))==='none', 'invisible recaptcha ignored');
check(k(run('<title>Just a moment...</title>', 'https://kr.supreme.com/'))==='captcha', 'cloudflare challenge');
check(k(run('<h1>You’re in line to check out</h1>', 'https://kr.supreme.com/'))==='queue', 'shopify "in line to check out"');
const qi = run('<h1>접속 대기 중</h1><p>내 앞에 12,345명이 있습니다. 예상 대기 시간 7분</p>', 'https://kr.supreme.com/');
check(qi.msgs[0].info==='앞에 12,345명 · 예상 7분', 'queue info parsed: '+qi.msgs[0].info);
const qe = run('<h1>You are now in line</h1><p>Your number in line: 532. Expected wait time: 3 minutes</p>', 'https://x.queue-it.net/');
check(qe.msgs[0].info==='앞에 532명 · 예상 3 minutes', 'queue info EN: '+qe.msgs[0].info);
// transition queue → none after navigation-like change
(async()=>{
  const t = run('<h1>You are in line</h1>', 'https://kr.supreme.com/');
  t.w.document.querySelector('h1').textContent = 'New Arrivals';
  await new Promise(r=>setTimeout(r,1300));
  check(k(t)==='queue,none', 'queue → none transition reported: '+k(t));
  console.log(ok?'ALL PASS':'SOME FAILED'); process.exit(ok ? 0 : 1);
})();
