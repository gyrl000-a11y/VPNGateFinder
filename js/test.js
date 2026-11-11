const { JSDOM } = require('jsdom');
const fs = require('fs');
const AUTOFILL = fs.readFileSync(process.argv[2] + '/js/autofill.js', 'utf8');
const HOOK = fs.readFileSync(process.argv[2] + '/js/hook.js', 'utf8');
const addr = { email:'a@b.com', phone:'010-1234-5678', lastName:'김', firstName:'혁', postal:'21300', province:'인천광역시', city:'부평구', address1:'산곡로 1', address2:'101동 1001호' };
const card = { number:'4111 1111 1111 1111', name:'HYUK KIM', month:'7', year:'2029', cvc:'123' };

function mk(html, url, cfg) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  w.HTMLElement.prototype.getBoundingClientRect = function(){ return {width:100,height:20,top:0,left:0}; };
  Object.defineProperty(w.HTMLElement.prototype, 'innerText', { get(){ return this.textContent; } });
  const msgs = [];
  w.webkit = { messageHandlers: {
    df: { postMessage(m){ msgs.push(m); return Promise.resolve(m.type==='config'?cfg:null); } },
    dfhook: { postMessage(m){ msgs.push(m); } } } };
  const clicks = [];
  w.document.addEventListener('click', e => clicks.push(e.target.textContent.trim() || e.target.name), true);
  return { dom, w, msgs, clicks };
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

const zone = `<select name="zone" autocomplete="shipping address-level1" id="z"><option value="">시/도</option><option value="KR-11">서울특별시</option><option value="KR-28">인천광역시</option><option value="KR-41">경기도</option></select>`;
const country = `<select name="countryCode" autocomplete="shipping country"><option value="US">미국</option><option value="KP">조선민주주의인민공화국</option><option value="KR">대한민국</option></select>`;
const fields = `
<label for="em">이메일</label><input id="em" name="email" autocomplete="email">
${country}
<input name="lastName" autocomplete="shipping family-name">
<input name="firstName" autocomplete="shipping given-name">
<input name="postalCode" autocomplete="shipping postal-code">
${zone}
<input name="city" autocomplete="shipping address-level2">
<input name="address1" autocomplete="shipping address-line1">
<input name="address2" autocomplete="shipping address-line2">
<input name="phone" autocomplete="shipping tel">
<label for="dc">할인 코드 또는 기프트 카드</label><input id="dc" name="reductions">`;

(async () => {
  let ok = true; const check = (c, m) => { console.log((c?'PASS ':'FAIL ') + m); if(!c) ok=false; };

  // 1 one-page checkout
  let t = mk(`<body>${fields}<button type="submit">지금 결제</button></body>`, 'https://kr.supreme.com/checkouts/cn/abc', {enabled:true,autoCheckout:true,address:addr,card});
  t.w.eval(AUTOFILL); await sleep(1500);
  const d = t.w.document, v = n => d.querySelector(`[name="${n}"]`).value;
  check(v('countryCode')==='KR', 'country KR (not KP)');
  check(v('zone')==='KR-28', 'province 인천 → KR-28');
  check(v('lastName')==='김' && v('firstName')==='혁' && v('address2')==='101동 1001호' && v('email')==='a@b.com', 'text fields');
  check(v('reductions')==='', 'discount code untouched');
  check(t.clicks.length===0, 'pay button NOT clicked');
  check(d.querySelector('button').style.outline.includes('3px'), 'pay button highlighted');
  check(t.msgs.some(m=>m.type==='ready'), 'ready message');

  // 2 legacy multi-step
  t = mk(`<body>${fields}<button type="submit">배송으로 계속</button></body>`, 'https://shop-kr.palaceskateboards.com/checkouts/abc?step=contact_information', {enabled:true,autoCheckout:true,address:addr});
  t.w.eval(AUTOFILL); await sleep(2000);
  check(t.clicks.includes('배송으로 계속'), 'continue clicked');

  // 2b autoCheckout off → no continue click
  t = mk(`<body>${fields}<button type="submit">배송으로 계속</button></body>`, 'https://shop-kr.palaceskateboards.com/checkouts/abc', {enabled:true,autoCheckout:false,address:addr});
  t.w.eval(AUTOFILL); await sleep(2000);
  check(t.clicks.length===0, 'no continue when auto off');

  // 3 cart page
  t = mk(`<body><button name="checkout">체크아웃</button><button>Shop Pay</button></body>`, 'https://shop-kr.palaceskateboards.com/cart', {enabled:true,autoCheckout:true,address:addr});
  t.w.eval(AUTOFILL); await sleep(800);
  check(t.clicks.length===1 && t.clicks[0]==='체크아웃', 'cart checkout clicked once');

  // 4 card iframe
  t = mk(`<body><input name="number" autocomplete="cc-number"><input name="expiry" autocomplete="cc-exp"><input name="verification_value" autocomplete="cc-csc"><input name="name"></body>`, 'https://checkout.pci.shopifyinc.com/build/x/number-ltr.html', {enabled:true,autoCheckout:true,card});
  t.w.eval(AUTOFILL); await sleep(500);
  const cv = n => t.w.document.querySelector(`[name="${n}"]`).value;
  check(cv('number')==='4111111111111111' && cv('expiry')==='07 / 29' && cv('verification_value')==='123' && cv('name')==='HYUK KIM', 'card frame filled: '+[cv('number'),cv('expiry'),cv('name')].join('|'));

  // 5 disabled host
  t = mk(`<body>${fields}</body>`, 'https://evil.example.com/', {enabled:false});
  t.w.eval(AUTOFILL); await sleep(300);
  check(t.w.document.querySelector('[name=email]').value==='', 'not filled when disabled');

  // 6 hook: fetch /cart/add.js and GraphQL
  t = mk(`<body></body>`, 'https://kr.supreme.com/products/x', {});
  t.w.fetch = async (u, i) => ({ ok: true, clone(){ return { json: async () => (String(u).includes('graphql') ? {data:{cartLinesAdd:{cart:{checkoutUrl:'https://kr.supreme.com/cart/c/xyz'},userErrors:[]}}} : {id:1}) }; } });
  t.w.eval(HOOK);
  await t.w.fetch('/cart/add.js', {method:'POST', body: 'id=1'});
  await t.w.fetch('/api/2024-01/graphql.json', {method:'POST', body: JSON.stringify({query:'mutation cartLinesAdd', variables:{}})});
  await t.w.fetch('/api/2024-01/graphql.json', {method:'POST', body: JSON.stringify({query:'mutation cartCreate', variables:{input:{}}})});
  await sleep(50);
  const added = t.msgs.filter(m=>m.type==='added');
  check(added.length===2 && added[1].checkoutUrl==='https://kr.supreme.com/cart/c/xyz', 'hook: 2 adds, empty cartCreate ignored, checkoutUrl found');

  console.log(ok ? 'ALL PASS' : 'SOME FAILED');
  process.exit(ok ? 0 : 1);
})();
