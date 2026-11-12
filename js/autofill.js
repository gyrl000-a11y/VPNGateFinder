// DropFill autofill — runs in an isolated content world (page scripts can't see these variables).
// Gets profile/card from the app only for allowed hosts. Never clicks the final pay button.
(function () {
  'use strict';
  if (window.__dfLoaded) return;
  window.__dfLoaded = true;

  var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.df;
  if (!H) return;

  var IS_TOP = window === window.top;
  var LIFETIME = 10 * 60 * 1000;

  // 최종 결제 버튼 — 절대 클릭하지 않고 표시만 한다
  var PAY_RE = /지금\s*결제|결제\s*하기|주문\s*하기|주문\s*완료|구매\s*하기|주문\s*검토|pay\s*now|complete\s*(order|purchase)|place\s*order|submit\s*order|review\s*order|buy\s*now/i;
  // 다단계 체크아웃에서 다음 단계로 넘어가는 버튼
  var CONTINUE_RE = /(배송|결제|shipping|payment|delivery)[\s\S]{0,15}(계속|continue)|continue\s*to\s*(shipping|payment|delivery)/i;
  // 장바구니 페이지의 체크아웃 버튼
  var CART_CHECKOUT_RE = /체크\s*아웃|check\s*out|결제\s*하기|주문\s*하기|구매\s*하기/i;
  var EXPRESS_RE = /shop\s*pay|apple|google|paypal|kakao|naver|카카오|네이버|페이코|toss|토스/i;
  // 장바구니 약관 동의 체크 (마케팅·수신 동의는 건드리지 않음)
  var AGREE_RE = /동의|agree|terms|약관|conditions|accept|years\s*or\s*older|14\s*세\s*이상|만\s*14/i;
  // 마케팅·수신 동의, '전체 동의'(다른 체크를 한꺼번에 뒤집을 수 있음), 정보 저장 체크는 건드리지 않음
  var AGREE_SKIP_RE = /마케팅|광고|newsletter|뉴스레터|sms|문자|수신|marketing|subscribe|promotion|혜택|이벤트|accept\s*all|agree\s*to\s*all|select\s*all|전체\s*동의|모두\s*동의|save\s*this|저장/i;
  var SKIP_RE = /discount|reduction|gift|coupon|promo|할인|쿠폰|기프트|search|검색|newsletter|뉴스레터|sign-?up|subscribe|mailing|구독|password|비밀번호|company|회사/i;

  var KR_REGIONS = [
    ['서울', 'KR-11', 'seoul'], ['부산', 'KR-26', 'busan'], ['대구', 'KR-27', 'daegu'],
    ['인천', 'KR-28', 'incheon'], ['광주', 'KR-29', 'gwangju'], ['대전', 'KR-30', 'daejeon'],
    ['울산', 'KR-31', 'ulsan'], ['세종', 'KR-50', 'sejong'], ['경기', 'KR-41', 'gyeonggi'],
    ['강원', 'KR-42', 'gangwon'], ['충청북', 'KR-43', 'north chungcheong'], ['충북', 'KR-43', 'chungbuk'],
    ['충청남', 'KR-44', 'south chungcheong'], ['충남', 'KR-44', 'chungnam'],
    ['전라북', 'KR-45', 'north jeolla'], ['전북', 'KR-45', 'jeonbuk'],
    ['전라남', 'KR-46', 'south jeolla'], ['전남', 'KR-46', 'jeonnam'],
    ['경상북', 'KR-47', 'north gyeongsang'], ['경북', 'KR-47', 'gyeongbuk'],
    ['경상남', 'KR-48', 'south gyeongsang'], ['경남', 'KR-48', 'gyeongnam'], ['제주', 'KR-49', 'jeju']
  ];

  var AC_MAP = {
    'email': 'email', 'tel': 'phone', 'tel-national': 'phone',
    'family-name': 'lastName', 'given-name': 'firstName', 'name': 'fullName',
    'postal-code': 'postal', 'address-level1': 'province', 'address-level2': 'city',
    'address-line1': 'address1', 'street-address': 'address1', 'address-line2': 'address2',
    'country': 'country', 'country-name': 'country',
    'cc-number': 'ccNumber', 'cc-name': 'ccName', 'cc-exp': 'ccExp',
    'cc-exp-month': 'ccMonth', 'cc-exp-year': 'ccYear', 'cc-csc': 'ccCsc'
  };

  // Shopify 카드 입력 iframe 안의 필드 이름
  var CARD_FRAME_NAMES = { 'number': 'ccNumber', 'name': 'ccName', 'expiry': 'ccExp', 'verification_value': 'ccCsc' };

  var NAME_RULES = [
    ['customs', /pccc|customs|clearance|tongwan|personal.?code/],
    ['birth', /birth|dob|birthday/],
    ['ccNumber', /card.?number|cc.?num|cardno/],
    ['ccCsc', /cvv|cvc|csc|verification|security.?code/],
    ['ccExp', /expiry|exp.?date|expiration/],
    ['ccName', /card.?holder|name.?on.?card|cc.?name/],
    ['email', /e.?mail/],
    ['phone', /phone|mobile|(^|[^a-z])tel([^a-z]|$)/],
    ['lastName', /last.?name|family.?name|surname/],
    ['firstName', /first.?name|given.?name/],
    ['postal', /postal|zip|postcode/],
    ['province', /province|zone|(^|[^a-z])state([^a-z]|$)|region/],
    ['city', /city/],
    ['address2', /address.?2|address.?line.?2|apartment|suite/],
    ['address1', /address.?1|address.?line.?1|street|^address$/],
    ['country', /country/]
  ];

  var LABEL_RULES = [
    ['customs', /개인\s*통관|통관\s*고유|통관\s*번호|customs|clearance\s*code|pccc/i],
    ['birth', /생년\s*월일|생일|date\s*of\s*birth|birth\s*date|birthday/i],
    ['ccNumber', /카드\s*번호|card\s*number/i],
    ['ccCsc', /보안\s*코드|cvc|cvv|security\s*code/i],
    ['ccExp', /유효\s*기간|만료|expir/i],
    ['ccName', /카드\s*소유자|카드\s*명의|name\s*on\s*card|cardholder/i],
    ['email', /이메일|e-?mail/i],
    ['phone', /전화|휴대폰|연락처|phone/i],
    ['postal', /우편\s*번호|postal|zip/i],
    ['province', /시\s*\/\s*도|광역|province|state|region/i],
    ['city', /시\s*\/\s*군|군\s*\/\s*구|도시|city/i],
    ['address2', /상세\s*주소|아파트|동\s*\/\s*호|호수|address\s*line\s*2|apartment|suite/i],
    ['address1', /^\s*주소|도로명|^\s*address/i],
    ['lastName', /^\s*성\s*($|\()|last\s*name|family\s*name|surname/i],
    ['firstName', /^\s*이름\s*($|\()|first\s*name|given\s*name/i]
  ];

  var cfg = null;
  var touched = new WeakSet();
  var fillCount = new WeakMap();
  var clicked = {};
  var payMarked = null;
  var started = Date.now();
  var timer = null;

  function post(m) {
    try { var p = H.postMessage(m); if (p && p.catch) p.catch(function () {}); } catch (e) {}
  }

  function norm(s) { return String(s == null ? '' : s).toLowerCase().replace(/\s+/g, ''); }
  function pad2(v) { v = String(v).replace(/\D/g, ''); return v.length === 1 ? '0' + v : v.slice(-2); }
  function txt(el) {
    return String(el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
  }

  function visible(el) {
    if (!el || el.type === 'hidden') return false;
    var r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return false;
    var cs = window.getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none';
  }

  function labelText(el) {
    var parts = [];
    try { if (el.labels) for (var i = 0; i < el.labels.length; i++) parts.push(el.labels[i].innerText); } catch (e) {}
    var lb = el.getAttribute('aria-labelledby');
    if (lb) lb.split(/\s+/).forEach(function (id) { var n = document.getElementById(id); if (n) parts.push(n.innerText); });
    parts.push(el.getAttribute('aria-label') || '', el.getAttribute('placeholder') || '');
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  }

  function isFillable(el) {
    if (el.disabled || el.readOnly) return false;
    var t = (el.type || '').toLowerCase();
    if (/^(hidden|checkbox|radio|submit|button|file|image|reset|password|search|range|color)$/.test(t)) return false;
    return visible(el);
  }

  function keyFor(el) {
    if (el.__dfKey !== undefined) return el.__dfKey;
    var k = computeKey(el);
    el.__dfKey = k;
    return k;
  }

  var PIN2_NAME_RE = /pin.?code.?first|first.?two.?digits|card.?pw.?2|cardpin2/;
  var PIN2_LABEL_RE = /pin\s*code\s*first\s*two|비밀번호\s*앞\s*(2|두)|앞\s*2\s*자리/i;
  var SKIP_KEY_RE = /phone.?country|phone.?code|dial.?code/;   // 전화 국가번호 선택칸 (배송 국가칸 countryCode 와 구분)

  function computeKey(el) {
    var nameId = ((el.getAttribute('name') || '') + ' ' + (el.id || '')).toLowerCase();
    var label = labelText(el);
    // 카드 비밀번호 앞 2자리는 'password' 제외 규칙보다 먼저 확인
    if (PIN2_NAME_RE.test(nameId) || PIN2_LABEL_RE.test(label)) return 'pin2';
    if (SKIP_KEY_RE.test(nameId)) return null;
    if (SKIP_RE.test(nameId) || SKIP_RE.test(label)) return null;

    var ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).filter(Boolean);
    var last = ac[ac.length - 1];
    if (last && AC_MAP[last]) return AC_MAP[last];

    if (cfg.card && !cfg.address) {
      var n = (el.getAttribute('name') || '').toLowerCase();
      if (CARD_FRAME_NAMES[n]) return CARD_FRAME_NAMES[n];
    }
    var i;
    for (i = 0; i < NAME_RULES.length; i++) if (NAME_RULES[i][1].test(nameId)) return NAME_RULES[i][0];
    for (i = 0; i < LABEL_RULES.length; i++) if (LABEL_RULES[i][1].test(label)) return LABEL_RULES[i][0];
    return null;
  }

  function isCardKey(k) { return k.indexOf('cc') === 0; }
  function isIdKey(k) { return k === 'birth' || k === 'customs' || k === 'pin2'; }
  function allowedKey(k) {
    if (isCardKey(k)) return !!cfg.card;
    if (isIdKey(k)) return !!cfg.identity;
    return !!cfg.address;
  }

  // 생년월일 형식은 칸 모양을 보고 맞춘다 (date 입력, 6/8자리, 구분자)
  function birthFor(el, d) {
    d = String(d || '').replace(/\D/g, '');
    if (d.length !== 8) return null;
    var y = d.slice(0, 4), m = d.slice(4, 6), dd = d.slice(6, 8);
    if ((el.type || '').toLowerCase() === 'date') return y + '-' + m + '-' + dd;
    var hint = (el.getAttribute('placeholder') || '') + ' ' + labelText(el);
    if (el.maxLength === 6 || /6\s*자리|yymmdd/i.test(hint)) return d.slice(2);
    if (el.maxLength === 8 || /8\s*자리|yyyymmdd/i.test(hint)) return d;
    if (/\d{4}-\d{2}-\d{2}|yyyy-mm-dd/i.test(hint)) return y + '-' + m + '-' + dd;
    if (/\d{4}\.\d{2}\.\d{2}|yyyy\.mm\.dd/i.test(hint)) return y + '.' + m + '.' + dd;
    if (/\d{4}\/\d{2}\/\d{2}|yyyy\/mm\/dd/i.test(hint)) return y + '/' + m + '/' + dd;
    if (/mm\/dd\/yyyy/i.test(hint)) return m + '/' + dd + '/' + y;
    if (el.maxLength === 10) return y + '-' + m + '-' + dd;
    return d;
  }

  function region(p) {
    for (var i = 0; i < KR_REGIONS.length; i++) if (String(p).indexOf(KR_REGIONS[i][0]) >= 0) return KR_REGIONS[i];
    return null;
  }

  function valueFor(key, el) {
    var a = cfg.address || {}, c = cfg.card || {};
    switch (key) {
      case 'email': return a.email;
      case 'phone': return a.phone;
      case 'lastName': return a.lastName;
      case 'firstName': return a.firstName;
      case 'fullName': return a.fullName || ((a.lastName || '') + (a.firstName || ''));
      case 'postal': return a.postal;
      case 'province': return a.province;
      case 'city': return a.city;
      case 'address1': return a.address1;
      case 'address2': return a.address2;
      case 'country': return cfg.address ? 'KR' : null;
      case 'ccNumber': return c.number ? String(c.number).replace(/\D/g, '') : null;
      case 'ccName': return c.name;
      case 'ccExp':
        if (!c.month || !c.year) return null;
        var mm = pad2(c.month), yy = String(c.year).slice(-2);
        if (el.maxLength === 4) return mm + yy;
        if (el.maxLength === 5) return mm + '/' + yy;
        return mm + ' / ' + yy;
      case 'ccMonth': return c.month ? pad2(c.month) : null;
      case 'ccYear': return c.year ? String(c.year) : null;
      case 'ccCsc': return c.cvc;
      case 'birth': return cfg.identity ? birthFor(el, cfg.identity.birth) : null;
      case 'customs': return cfg.identity && cfg.identity.customs ? String(cfg.identity.customs).toUpperCase() : null;
      case 'pin2': return cfg.identity && cfg.identity.pin2 ? String(cfg.identity.pin2).replace(/\D/g, '').slice(0, 2) : null;
    }
    return null;
  }

  function selectCandidates(key, v) {
    if (key === 'country') return ['KR', 'KOR', '대한민국', 'south korea', 'korea, republic of', 'republic of korea'];
    if (key === 'province') {
      var ko = (cfg.address && cfg.address.provinceKo) || v;
      var r = region(ko), out = [v, ko];
      if (r) out.push(r[1], r[0], r[2]);
      return out;
    }
    if (key === 'ccMonth') return [v, String(parseInt(v, 10))];
    if (key === 'ccYear') return [v, v.slice(-2), '20' + v.slice(-2)];
    return [v];
  }

  function pickOption(sel, cands) {
    var opts = Array.prototype.slice.call(sel.options).filter(function (o) {
      return !o.disabled && !/democratic|north|북한|조선/i.test(o.text);
    });
    var i, j, c;
    for (i = 0; i < cands.length; i++) {
      c = norm(cands[i]);
      if (!c) continue;
      for (j = 0; j < opts.length; j++) if (norm(opts[j].value) === c || norm(opts[j].text) === c) return opts[j];
    }
    for (i = 0; i < cands.length; i++) {
      c = norm(cands[i]);
      if (c.length < 2) continue;
      for (j = 0; j < opts.length; j++) if (norm(opts[j].text).indexOf(c) >= 0) return opts[j];
    }
    return null;
  }

  var inputSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  var areaSetter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
  var selectSetter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set;

  function fire(el) {
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function leave(el) {
    if (document.activeElement === el) { try { el.blur(); } catch (e) {} }
    else {
      el.dispatchEvent(new FocusEvent('blur'));
      el.dispatchEvent(new FocusEvent('focusout', { bubbles: true }));
    }
  }

  function setText(el, v) {
    try { el.focus({ preventScroll: true }); } catch (e) {}
    (el.tagName === 'TEXTAREA' ? areaSetter : inputSetter).call(el, v);
    try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: v })); }
    catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    leave(el);
  }

  // 한 번에 넣은 값을 사이트가 지워 버리는 칸(결제 옵션 확장 칸 등)은 한 글자씩 입력
  function typeText(el, v) {
    var setter = el.tagName === 'TEXTAREA' ? areaSetter : inputSetter;
    try { el.focus({ preventScroll: true }); } catch (e) {}
    setter.call(el, '');
    for (var i = 0; i < v.length; i++) {
      var ch = v.charAt(i);
      el.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true }));
      try { el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: ch })); } catch (e) {}
      setter.call(el, el.value + ch);
      try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: ch })); }
      catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
      el.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    leave(el);
  }

  function setSelect(el, cands) {
    var opt = pickOption(el, cands);
    if (!opt || el.value === opt.value) return false;
    selectSetter.call(el, opt.value);
    fire(el);
    return true;
  }

  function pass() {
    var list = [];
    var els = document.querySelectorAll('input, select, textarea');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (touched.has(el) || !isFillable(el)) continue;
      var key = keyFor(el);
      if (!key) continue;
      if (!allowedKey(key)) continue;
      list.push([el, key]);
    }
    // 국가를 먼저 맞춰야 주소 칸이 한국 형식으로 다시 그려진다
    list.sort(function (a, b) { return (a[1] === 'country' ? 0 : 1) - (b[1] === 'country' ? 0 : 1); });

    var filled = 0;
    for (var k = 0; k < list.length; k++) {
      var e = list[k][0], key2 = list[k][1];
      var v = valueFor(key2, e);
      if (v == null || v === '') continue;
      v = String(v);
      if (e.tagName === 'SELECT') {
        if (setSelect(e, selectCandidates(key2, v))) filled++;
        if (key2 === 'country' && filled) break; // 다시 그려질 때까지 기다림
      } else if (key2 !== 'country' && !e.value) {
        var tries = fillCount.get(e) || 0;
        if (tries >= 5) continue;                 // 계속 지워지면 포기 (무한 반복 방지)
        fillCount.set(e, tries + 1);
        if (tries === 0) setText(e, v); else typeText(e, v);
        filled++;
      }
    }
    return filled;
  }

  function findButton(pred, selector) {
    var els = document.querySelectorAll(selector || 'button, input[type="submit"], [role="button"], a');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (!visible(el)) continue;
      var t = txt(el);
      if (t && pred(t, el)) return el;
    }
    return null;
  }

  function clickOnce(key, el, delay, msg) {
    if (clicked[key]) return;
    clicked[key] = true;
    setTimeout(function () {
      if (!document.contains(el) || el.disabled) { clicked[key] = false; return; }
      if (PAY_RE.test(txt(el)) && !/\/cart\/?$/.test(location.pathname)) return; // 안전장치
      el.click();
      if (msg) post({ type: 'log', msg: msg });
    }, delay);
  }

  function hasEmptyRequired() {
    var els = document.querySelectorAll('input[required], input[aria-required="true"], select[required], select[aria-required="true"]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.type === 'checkbox' || el.type === 'radio') continue;
      if (visible(el) && !el.value) return true;
    }
    return false;
  }

  // 체크박스마다 '한 번 누르고 기다렸다가 확인'. 사이트가 체크 표시를 늦게 바꾸는 경우가 있어
  // 바로 다시 누르거나 checked 를 강제로 켜면 사이트 내부 상태와 화면이 반대가 된다 (Palace 장바구니).
  var agreeTried = {};
  function checkAgreements() {
    var boxes = document.querySelectorAll('input[type="checkbox"]');
    var n = 0, now = Date.now();
    for (var i = 0; i < boxes.length; i++) {
      var cb = boxes[i];
      if (cb.checked || cb.disabled || touched.has(cb)) continue;
      // 자기 라벨을 우선 사용 (묶음 전체 글자를 보면 '전체 동의' 같은 옆 문구가 섞임)
      var t = labelText(cb);
      if (!t) {
        var box = cb.closest('label, li, p, div');
        t = box ? (box.innerText || box.textContent || '') : '';
      }
      t = t.slice(0, 300);
      if (!AGREE_RE.test(t) || AGREE_SKIP_RE.test(t)) continue;
      var k = location.pathname + '|' + (cb.id || cb.name || t.slice(0, 40));
      var st = agreeTried[k] || { n: 0, at: 0 };
      if (st.n >= 2 || now - st.at < 900) continue;      // 최대 2번, 시도 사이 0.9초 대기
      st.n += 1; st.at = now; agreeTried[k] = st;
      if (st.n === 1) cb.click();
      else { var lb = cb.labels && cb.labels[0]; (lb || cb).click(); }  // 첫 시도가 안 먹힌 경우만
      n++;
    }
    if (n) post({ type: 'log', msg: '약관 동의 체크' });
    return n;
  }

  function clickCartCheckout() {
    if (cfg.autoAgree) checkAgreements();
    var el = null;
    var named = document.querySelectorAll('button[name="checkout"], input[name="checkout"]');
    for (var i = 0; i < named.length; i++) if (visible(named[i])) { el = named[i]; break; }
    if (!el) el = findButton(function (t) { return CART_CHECKOUT_RE.test(t) && !EXPRESS_RE.test(t); });
    if (el && !el.disabled) clickOnce('cart:' + location.href, el, 250, '체크아웃으로 넘어가는 중');
  }

  function tryContinue() {
    if (hasEmptyRequired()) return;
    var b = findButton(function (t) { return CONTINUE_RE.test(t) && !PAY_RE.test(t); }, 'button, input[type="submit"]');
    if (b && !b.disabled) clickOnce('cont:' + location.href + ':' + txt(b), b, 700, '다음 단계로 진행');
  }

  function markPay() {
    var b = findButton(function (t) { return PAY_RE.test(t); }, 'button, input[type="submit"]');
    if (!b || b === payMarked) return;
    payMarked = b;
    b.style.outline = '3px solid #ff2d55';
    b.style.outlineOffset = '3px';
    post({ type: 'ready' });
  }

  function afterFill() {
    var path = location.pathname;
    var onCart = /\/cart\/?$/.test(path);
    var onCheckout = /checkout/i.test(path);
    if (cfg.autoCheckout && onCart) clickCartCheckout();
    if (onCheckout) {
      if (cfg.autoAgree) checkAgreements();   // 체크아웃의 필수 동의(약관·14세 이상 등)
      if (cfg.autoCheckout) tryContinue();
      markPay();
    }
  }

  function run() {
    timer = null;
    var n = 0;
    try { n = pass(); } catch (e) { post({ type: 'log', msg: 'fill error: ' + e.message }); }
    if (n > 0) post({ type: 'filled', count: n, card: !cfg.address });
    if (IS_TOP && cfg.address) { try { afterFill(); } catch (e) {} }
  }

  function schedule(ms) {
    if (timer) return;
    timer = setTimeout(run, ms || 0);
  }

  function start() {
    document.addEventListener('input', function (e) { if (e.isTrusted && e.target) touched.add(e.target); }, true);
    document.addEventListener('change', function (e) { if (e.isTrusted && e.target) touched.add(e.target); }, true);
    new MutationObserver(function () {
      if (Date.now() - started < LIFETIME) schedule(300);
    }).observe(document.documentElement, { childList: true, subtree: true });
    var iv = setInterval(function () {
      if (Date.now() - started > LIFETIME) { clearInterval(iv); return; }
      schedule(0);
    }, 1200);
    window.__dfRun = function () { started = Date.now(); touched = new WeakSet(); clicked = {}; run(); };
    run();
  }

  // 진단 모드: 이 화면의 입력칸·버튼 목록(값은 빼고)을 앱에 보냄 → 설정의 '진단 결과'에서 복사
  function diagSnapshot() {
    var out = [];
    var els = document.querySelectorAll('input, select, textarea');
    for (var i = 0; i < els.length && out.length < 60; i++) {
      var el = els[i];
      var t = (el.type || el.tagName).toLowerCase();
      if (t === 'hidden') continue;
      var key = null;
      try { key = cfg.address || cfg.card || cfg.identity ? keyFor(el) : computeKey(el); } catch (e) {}
      out.push([
        el.tagName.toLowerCase() + (el.type ? ':' + el.type : ''),
        'name=' + (el.getAttribute('name') || ''),
        'id=' + (el.id || ''),
        'ac=' + (el.getAttribute('autocomplete') || ''),
        'label=' + labelText(el).slice(0, 50),
        'key=' + (key || '-'),
        (el.type === 'checkbox' || el.type === 'radio') ? (el.checked ? 'checked' : 'unchecked') : (el.value ? 'filled' : 'empty'),
        fillCount.get(el) ? 'tries=' + fillCount.get(el) : '',
        visible(el) ? '' : 'hidden'
      ].join(' | '));
    }
    var btns = [];
    var bs = document.querySelectorAll('button, input[type="submit"], [role="button"]');
    for (var j = 0; j < bs.length && btns.length < 25; j++) {
      if (!visible(bs[j])) continue;
      var tx = txt(bs[j]).slice(0, 40);
      if (tx) btns.push(tx + (bs[j].disabled ? ' (disabled)' : ''));
    }
    return 'fields:\n' + out.join('\n') + '\nbuttons: ' + btns.join(' / ');
  }

  function startDiag() {
    var last = '';
    window.__dfDiagState = 'started';
    function tick() {
      window.__dfDiagState = 'tick';
      var snap;
      try { snap = diagSnapshot(); } catch (e) { snap = 'diag error: ' + e.message; }
      if (snap === last) return;
      last = snap;
      window.__dfDiagState = 'posted';
      post({ type: 'diag', top: IS_TOP, url: location.href.split('?')[0], snapshot: snap });
    }
    setTimeout(tick, 1500);
    setInterval(tick, 3000);
  }

  H.postMessage({ type: 'config' }).then(function (c) {
    cfg = c || {};
    window.__dfCfgKeys = Object.keys(cfg).join(',') + ' diag=' + cfg.diag;
    if (cfg.diag) startDiag();
    if (cfg.enabled) start();
  }).catch(function () {});
})();
