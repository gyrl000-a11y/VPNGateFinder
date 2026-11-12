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
  t = mk(`<body>${fields}<button type="submit">배송으로 계속</button></body>`, 'https://kr.palaceskateboards.com/checkouts/abc?step=contact_information', {enabled:true,autoCheckout:true,address:addr});
  t.w.eval(AUTOFILL); await sleep(2000);
  check(t.clicks.includes('배송으로 계속'), 'continue clicked');

  // 2b autoCheckout off → no continue click
  t = mk(`<body>${fields}<button type="submit">배송으로 계속</button></body>`, 'https://kr.palaceskateboards.com/checkouts/abc', {enabled:true,autoCheckout:false,address:addr});
  t.w.eval(AUTOFILL); await sleep(2000);
  check(t.clicks.length===0, 'no continue when auto off');

  // 3 cart page
  t = mk(`<body><button name="checkout">체크아웃</button><button>Shop Pay</button></body>`, 'https://kr.palaceskateboards.com/cart', {enabled:true,autoCheckout:true,address:addr});
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

  // 7 hook: 요청 감지 없이도 /cart.js 수량 변화로 담기 감지 (Palace 대비)
  t = mk(`<body><button id="add">장바구니 담기</button><button id="wish">위시리스트</button></body>`, 'https://kr.palaceskateboards.com/products/x', {});
  let count = 0;
  t.w.fetch = async (u) => ({ ok: true, json: async () => ({ item_count: count }), clone(){ return this; } });
  t.w.eval(HOOK);
  await sleep(50);
  t.w.document.getElementById('wish').click();
  await sleep(1200);
  check(!t.msgs.some(m=>m.type==='added'), 'non-add button ignored');
  t.w.document.getElementById('add').click();
  count = 1;
  await sleep(1300);
  check(t.msgs.filter(m=>m.type==='added').length===1, 'add detected via /cart.js count');

  // 8b Palace 방식 ①: 사이트 스크립트가 늦게(2.5초) 준비됨 + 상태를 뒤집는 방식 + 체크 표시는 0.1초 뒤 반영
  //    → 앱이 먼저 체크하면 '체크됐는데 버튼 꺼짐'이 됨 → 빠른 재시도로 맞춰야 함
  for (const hydrateAt of [800, 2500]) {
    t = mk(`<body><label><input type="checkbox" id="terms-checkbox"> 이용약관에 동의합니다 TERMS AND CONDITIONS</label><button name="checkout" id="co" disabled>CHECKOUT</button><input type="email" name="email" id="signup-email" autocomplete="email"><label><input type="checkbox" id="mailing-list-terms-checkbox"> 개인정보 수집·이용 및 광고성 정보 수신에 동의합니다</label></body>`, 'https://kr.palaceskateboards.com/cart', {enabled:true,autoCheckout:true,autoAgree:true,address:addr});
    const d=t.w.document, cb=d.getElementById('terms-checkbox'), co=d.getElementById('co'); let st=false;
    setTimeout(() => cb.addEventListener('click', e => { e.preventDefault(); st=!st; setTimeout(()=>{ cb.checked=st; co.disabled=!st; }, 100); }), hydrateAt);
    t.w.eval(AUTOFILL); await sleep(6000);
    check(cb.checked === true && st === true && co.disabled === false, `hydrate@${hydrateAt}ms: box and site agree (checked=${cb.checked}, state=${st})`);
    check(t.clicks.includes('CHECKOUT'), `hydrate@${hydrateAt}ms: CHECKOUT clicked`);
    check(d.getElementById('signup-email').value === '' && !d.getElementById('mailing-list-terms-checkbox').checked, `hydrate@${hydrateAt}ms: signup/ad consent untouched`);
  }

  // 8c 카드번호 안전장치: 쇼핑몰 본문에서 예전에 카드칸이었던 칸이 통관부호 칸으로 바뀌어도 카드번호를 넣지 않음
  t = mk(`<body><label for="f">Card number</label><input id="f" name="cardnumber"></body>`, 'https://shop.supreme.com/checkouts/cn/x/en-kr',
    {enabled:true,autoCheckout:true,address:addr,card,identity:{birth:'19900101',customs:'P123456789012',pin2:'12'}});
  t.w.eval(AUTOFILL); await sleep(500);
  { const d=t.w.document, f=d.getElementById('f');
    check(f.value === '', 'no card number in a main-page field without cc-* autocomplete');
    f.setAttribute('name', 'Personal Customs Code'); d.querySelector('label').textContent = 'Personal customs code';
    await sleep(1600);
    check(f.value === 'P123456789012', 'reused element re-detected as customs: ' + f.value); }

  // 10 Supreme 체크아웃(진단 결과 그대로): 필수 동의 체크, 전체 동의·정보 저장 건드리지 않음,
  //    통관부호 칸은 한 번에 넣으면 지워지고 한 글자씩 입력해야 받아들임, 카드 비밀번호 앞 2자리
  t = mk(`<body>
    <div id="grp">
    <label><input type="checkbox" id="save_shipping_information" name="save_shipping_information"> save this information for next time</label>
    <label><input type="checkbox" id="c0" name="custom-checkbox-0"> I am 14 years or older.</label>
    <label><input type="checkbox" id="c1" name="custom-checkbox-1"> I accept the Global-e terms &amp; conditions</label>
    <label><input type="checkbox" id="c2" name="custom-checkbox-2"> I accept the collection and use of my personal information</label>
    <label><input type="checkbox" id="c3" name="custom-checkbox-3"> Accept all</label>
    <label><input type="checkbox" id="tos" name="accept-tos"> I have read and agree to the Supreme Terms of Use</label>
    </div>
    <label for="dob">Date of birth (YYYY-MM-DD)</label><input id="extension-x--PaymentAdditionalField-Cards-PersonalCardDateOfBirth" autocomplete="on">
    <label for="pin">PIN code first two digits</label><input id="extension-x--PaymentAdditionalField-Cards-PersonalCardPinCodeFirstTwoDigits" autocomplete="on">
    <label for="pcc">Personal customs code</label><input id="pcc" name="Personal Customs Code" autocomplete="on">
    <select name="phone_country_select"><option value="KR">+82</option><option value="US">+1</option></select>
    <button type="submit">Pay now</button></body>`, 'https://shop.supreme.com/checkouts/cn/abc/en-kr',
    {enabled:true,autoCheckout:true,autoAgree:true,address:addr,identity:{birth:'19900101',customs:'P123456789012',pin2:'12'}});
  { const d=t.w.document;
    d.querySelector('label[for=dob]').htmlFor = d.querySelector('[id$=DateOfBirth]').id;
    d.querySelector('label[for=pin]').htmlFor = d.querySelector('[id$=FirstTwoDigits]').id;
    // 통관부호: 한 글자씩 들어온 입력(data 길이 1)만 받아들이고, 아니면 곧바로 지움
    const pcc = d.getElementById('pcc'); let typed = '';
    pcc.addEventListener('input', e => { if (e.data && e.data.length === 1) typed += e.data; else setTimeout(() => { pcc.value = typed; }, 30); });
    // 체크박스는 사이트가 늦게 반영
    ['c0','c1','c2','tos'].forEach(id => { const cb=d.getElementById(id); let st=false; cb.addEventListener('click', e => { e.preventDefault(); st=!st; setTimeout(()=>{ cb.checked=st; }, 80); }); });
    t.w.eval(AUTOFILL); await sleep(5000);
    check(['c0','c1','c2','tos'].every(id => d.getElementById(id).checked), 'Supreme required agreements checked');
    check(!d.getElementById('c3').checked && !d.getElementById('save_shipping_information').checked, '"Accept all" and "save info" untouched');
    check(d.querySelector('[id$=DateOfBirth]').value === '1990-01-01', 'DOB yyyy-mm-dd: ' + d.querySelector('[id$=DateOfBirth]').value);
    check(d.querySelector('[id$=FirstTwoDigits]').value === '12', 'PIN first two digits');
    check(pcc.value === 'P123456789012', 'customs code accepted via per-char typing: ' + pcc.value);
    check(d.querySelector('[name=phone_country_select]').value === 'KR', 'phone country select untouched');
    check(!t.clicks.some(c => /pay now/i.test(c)), 'pay button not clicked'); }

  // 8 cart page: 필수 약관만 체크하고 체크아웃
  t = mk(`<body><label><input type="checkbox" id="terms"> 이용약관에 동의합니다</label><label><input type="checkbox" id="mkt"> 마케팅 수신 동의</label><button name="checkout" id="co" disabled>체크아웃</button></body>`, 'https://kr.palaceskateboards.com/cart', {enabled:true,autoCheckout:true,autoAgree:true,address:addr});
  { const d8 = t.w.document; d8.getElementById('terms').addEventListener('change', e => { d8.getElementById('co').disabled = !e.target.checked; }); }
  t.w.eval(AUTOFILL); await sleep(3500);
  check(t.w.document.getElementById('terms').checked && !t.w.document.getElementById('mkt').checked, 'terms checked, marketing untouched');
  check(t.clicks.includes('체크아웃'), 'checkout clicked after agree');

  // 9 identity fields
  t = mk(`<body><label for="b">생년월일 (8자리)</label><input id="b" name="birth" maxlength="8"><label for="p">개인통관고유부호</label><input id="p" name="pccc"></body>`, 'https://kr.supreme.com/checkouts/cn/x', {enabled:true,autoCheckout:true,address:addr,identity:{birth:'19900101',customs:'P123456789012'}});
  t.w.eval(AUTOFILL); await sleep(600);
  check(t.w.document.getElementById('b').value==='19900101' && t.w.document.getElementById('p').value==='P123456789012', 'birth + customs filled');

  console.log(ok ? 'ALL PASS' : 'SOME FAILED');
  process.exit(ok ? 0 : 1);
})();
