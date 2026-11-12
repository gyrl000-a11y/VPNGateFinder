// 자동 생성 파일 — js/ 폴더를 고친 뒤 ./gen_scripts.sh 실행
enum Scripts {
    static let autofill = ##"""
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
  var selfAct = false;
  function act(fn) { selfAct = true; try { fn(); } finally { selfAct = false; } }
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

  function keySig(el) {
    return [el.getAttribute('name'), el.id, el.getAttribute('autocomplete'), el.getAttribute('placeholder'),
            el.getAttribute('aria-label'), el.getAttribute('aria-labelledby'), labelText(el)].join('|');
  }

  function keyFor(el) {
    var sig = keySig(el);
    if (el.__dfKey !== undefined && el.__dfSig === sig) return el.__dfKey;
    var k = computeKey(el);
    el.__dfKey = k;
    el.__dfSig = sig;
    return k;
  }

  // 카드 정보는 결제 전용 입력창(카드 도메인 iframe)이나 cc-* 로 명시된 칸에만
  function cardFieldOk(el, key) {
    if (!cfg.address) return true;                          // 카드 도메인 프레임
    var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
    return /(^|\s)cc-/.test(ac);
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
      if (isCardKey(key) && !cardFieldOk(el, key)) continue;
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
        var changed = false;
        act(function () { changed = setSelect(e, selectCandidates(key2, v)); });
        if (changed) filled++;
        if (key2 === 'country' && filled) break; // 다시 그려질 때까지 기다림
      } else if (key2 !== 'country' && !e.value) {
        var tries = fillCount.get(e) || 0;
        if (tries >= 5) continue;                 // 계속 지워지면 포기 (무한 반복 방지)
        fillCount.set(e, tries + 1);
        act(function () { if (tries === 0) setText(e, v); else typeText(e, v); });
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
      act(function () { el.click(); });
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
  var AGREE_FIRST_DELAY = 1500;     // 첫 체크는 페이지가 준비된 뒤 천천히
  var AGREE_REPAIR_GAP = 300;       // 체크했는데 버튼이 안 켜지면 빠르게 재시도
  var pageReadyAt = 0;

  function pageSettled(now) {
    if (document.readyState !== 'complete') return false;
    if (!pageReadyAt) pageReadyAt = now;
    return now - pageReadyAt >= AGREE_FIRST_DELAY;
  }

  // gateBtn: 이 동의에 따라 켜지는 버튼(장바구니 CHECKOUT). 체크돼 있는데 버튼이 계속 꺼져 있으면
  // 사이트가 체크를 못 알아챈 것 → 조용히 체크를 풀고 다시 클릭해서 사이트 상태와 맞춘다.
  function checkAgreements(gateBtn) {
    var now = Date.now();
    if (!pageSettled(now)) return 0;
    var boxes = document.querySelectorAll('input[type="checkbox"]');
    var n = 0;
    for (var i = 0; i < boxes.length; i++) {
      var cb = boxes[i];
      if (cb.disabled || touched.has(cb)) continue;
      // 자기 라벨을 우선 사용 (묶음 전체 글자를 보면 '전체 동의' 같은 옆 문구가 섞임)
      var t = labelText(cb);
      if (!t) {
        var box = cb.closest('label, li, p, div');
        t = box ? (box.innerText || box.textContent || '') : '';
      }
      t = t.slice(0, 300);
      if (!AGREE_RE.test(t) || AGREE_SKIP_RE.test(t)) continue;
      var k = location.pathname + '|' + (cb.id || cb.name || t.slice(0, 40));
      var st = agreeTried[k] || { n: 0, at: 0, rep: 0 };
      agreeTried[k] = st;
      if (!cb.checked) {
        if (st.n >= 2 || now - st.at < 900) continue;    // 체크 표시가 늦게 바뀌는 사이트 대비 0.9초 대기
        st.n += 1; st.at = now;
        if (st.n === 1) act(function () { cb.click(); });
        else { var lb = cb.labels && cb.labels[0]; act(function () { (lb || cb).click(); }); }
        n++;
      } else if (gateBtn && gateBtn.disabled && st.rep < 4 && now - st.at >= (st.rep ? 500 : 700)) {
        // 재시도 한 번마다 사이트 상태가 한 번 뒤집히므로, 사이트가 반영할 시간(0.5초)은 두고 다시 확인
        st.rep += 1; st.at = now;
        act(function () {
          cb.checked = false;        // 이벤트 없이 화면만 해제 → 한 번 클릭해서 사이트에 '체크'로 알림
          cb.click();
        });
        n++;
      }
    }
    if (n) post({ type: 'log', msg: '약관 동의 체크' });
    return n;
  }

  function cartCheckoutButton() {
    var named = document.querySelectorAll('button[name="checkout"], input[name="checkout"]');
    for (var i = 0; i < named.length; i++) if (visible(named[i])) return named[i];
    return findButton(function (t) { return CART_CHECKOUT_RE.test(t) && !EXPRESS_RE.test(t); });
  }

  var cartDone = false;
  function clickCartCheckout() {
    var el = cartCheckoutButton();
    if (cfg.autoAgree) checkAgreements(el);
    el = cartCheckoutButton();
    if (el && !el.disabled) {
      cartDone = true;
      clickOnce('cart:' + location.href, el, 250, '체크아웃으로 넘어가는 중');
    }
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
    // 장바구니에서는 체크아웃이 눌릴 때까지 0.3초마다 확인 (빠른 재시도)
    if (IS_TOP && cfg.address && cfg.autoCheckout && !cartDone && /\/cart\/?$/.test(location.pathname)
        && Date.now() - started < 60000) schedule(AGREE_REPAIR_GAP);
  }

  function schedule(ms) {
    if (timer) return;
    timer = setTimeout(run, ms || 0);
  }

  function start() {
    // 사용자가 직접 바꾼 칸만 '건드림'으로 기록 (앱 자신의 클릭·입력으로 생긴 이벤트는 제외)
    document.addEventListener('input', function (e) { if (e.isTrusted && !selfAct && e.target) touched.add(e.target); }, true);
    document.addEventListener('change', function (e) { if (e.isTrusted && !selfAct && e.target) touched.add(e.target); }, true);
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
"""##

    static let hook = ##"""
// DropFill hook — runs in the page world (top frame only).
// Detects a successful add-to-cart request and tells the app. Holds no personal data.
(function () {
  'use strict';
  if (window.__dfHook) return;
  window.__dfHook = true;

  function post(m) {
    try { window.webkit.messageHandlers.dfhook.postMessage(m); } catch (e) {}
  }

  var URL_RE = /\/cart\/add|\/cart\/lines|add[-_]?to[-_]?cart/i;

  function gqlAdds(url, body) {
    if (typeof body !== 'string' || !/graphql|\/api\//i.test(String(url || ''))) return false;
    if (/cartLinesAdd/.test(body)) return true;
    if (!/cartCreate/.test(body)) return false;
    try {
      var j = JSON.parse(body), v = j.variables || {};
      var lines = (v.input && v.input.lines) || v.lines || v.lineItems;
      return Array.isArray(lines) && lines.length > 0;
    } catch (e) {
      return /"lines"\s*:\s*\[\s*\{/.test(body);
    }
  }

  function isAdd(url, body) {
    return URL_RE.test(String(url || '')) || gqlAdds(url, body);
  }

  function hasErrors(o, depth) {
    if (!o || typeof o !== 'object' || depth > 6) return false;
    for (var k in o) {
      if (!Object.prototype.hasOwnProperty.call(o, k)) continue;
      var v = o[k];
      if ((k === 'userErrors' || k === 'errors') && Array.isArray(v) && v.length) return true;
      if (v && typeof v === 'object' && hasErrors(v, depth + 1)) return true;
    }
    return false;
  }

  function findCheckout(o, depth) {
    if (!o || typeof o !== 'object' || depth > 6) return null;
    for (var k in o) {
      if (!Object.prototype.hasOwnProperty.call(o, k)) continue;
      var v = o[k];
      if ((k === 'checkoutUrl' || k === 'webUrl' || k === 'checkout_url') && typeof v === 'string') return v;
      if (v && typeof v === 'object') { var r = findCheckout(v, depth + 1); if (r) return r; }
    }
    return null;
  }

  var lastReport = 0;
  function report(json) {
    if (json && hasErrors(json, 0)) return;
    lastReport = Date.now();
    post({ type: 'added', checkoutUrl: json ? findCheckout(json, 0) : null });
  }

  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (input, init) {
      var url = typeof input === 'string' ? input : (input && input.url);
      var body = init && init.body;
      var p = origFetch.apply(this, arguments);
      if (isAdd(url, typeof body === 'string' ? body : '')) {
        p.then(function (r) {
          if (!r || !r.ok) return;
          r.clone().json().then(report, function () { report(null); });
        }, function () {});
      }
      return p;
    };
  }

  // 요청 감지가 안 되는 사이트 대비: 담기 버튼을 누른 뒤 Shopify /cart.js 의 수량이 늘었는지 확인
  var ADD_TEXT = /add\s*to\s*(cart|bag|basket)|장바구니|카트에?\s*(추가|담기)|^\s*담기\s*$|^\s*add\s*$/i;
  var NOT_ADD = /checkout|결제|구매\s*하기|buy\s*now|wish|위시|관심|보기|view|이동|go\s*to/i;
  var baseCount = null;

  function cartCount() {
    if (!origFetch) return Promise.resolve(null);
    return origFetch.call(window, '/cart.js', { credentials: 'same-origin', headers: { Accept: 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) { return j && typeof j.item_count === 'number' ? j.item_count : null; })
      .catch(function () { return null; });
  }

  function refreshBase() { cartCount().then(function (c) { if (c !== null) baseCount = c; }); }

  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest && e.target.closest('button, input[type="submit"], [role="button"], a');
    if (!t) return;
    var label = String(t.innerText || t.value || t.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
    if (!label || label.length > 40 || !ADD_TEXT.test(label) || NOT_ADD.test(label)) return;
    var clickedAt = Date.now();
    var before = baseCount;
    [900, 2000, 4000].forEach(function (ms) {
      setTimeout(function () {
        if (lastReport >= clickedAt) return;              // 이미 요청 감지로 처리됨
        cartCount().then(function (c) {
          if (c === null || lastReport >= clickedAt) return;
          if (before === null ? c > 0 : c > before) { baseCount = c; report(null); }
        });
      }, ms);
    });
  }, true);

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refreshBase);
  else refreshBase();

  var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__dfUrl = u;
    return XO.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    var x = this;
    if (isAdd(x.__dfUrl, typeof body === 'string' ? body : '')) {
      x.addEventListener('load', function () {
        if (x.status < 200 || x.status >= 300) return;
        var j = null;
        try { j = JSON.parse(x.responseText); } catch (e) {}
        report(j);
      });
    }
    return XS.apply(this, arguments);
  };
})();
"""##

    static let gate = ##"""
// DropFill gate — 대기열·캡차 화면을 감지해서 앱에 알리기만 한다. 우회하거나 조작하지 않음.
// Isolated content world, top frame only, every site.
(function () {
  'use strict';
  if (window.__dfGate) return;
  window.__dfGate = true;

  var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.df;
  if (!H) return;

  var CAPTCHA_SEL = [
    'iframe[src*="hcaptcha.com"]', 'iframe[src*="/recaptcha/"]', 'iframe[src*="challenges.cloudflare.com"]',
    'iframe[src*="arkoselabs"]', 'iframe[src*="funcaptcha"]', 'iframe[src*="geo.captcha-delivery.com"]',
    '.h-captcha', '.g-recaptcha', '.cf-turnstile', '#challenge-form', '#cf-challenge-running'
  ].join(',');

  var QUEUE_HOST_RE = /(^|\.)queue-it\.net$|(^|\.)queue-it\.com$/i;
  var QUEUE_PATH_RE = /\/throttle\/queue|\/queue(\/|$)|waiting[-_]?room/i;
  var QUEUE_TEXT_RE = /대기열|대기\s*중|대기\s*순서|순서를\s*기다|접속\s*대기|체크\s*아웃\s*대기|줄을\s*서|you('|’)?re\s*in\s*line|you\s*are\s*(now\s*)?in\s*line|in\s*line\s*to\s*check\s*out|in\s*the\s*queue|waiting\s*room|your\s*place\s*in\s*line|high\s*demand/i;
  // 대기 순번·예상 시간 (페이지에 보이는 경우만)
  var POS_RE = /(?:대기\s*순번|대기\s*번호|내\s*순서|앞에|순번|number\s*in\s*line|position(?:\s*in\s*line)?|people\s*ahead|users?\s*ahead|ahead\s*of\s*you)[^0-9]{0,25}([0-9][0-9,]*)/i;
  var POS_RE2 = /([0-9][0-9,]*)\s*(?:명|people|users?)\s*(?:이\s*)?(?:앞|ahead)/i;
  var ETA_RE = /(?:예상\s*(?:대기)?\s*시간|남은\s*시간|expected\s*wait(?:ing)?\s*time|estimated\s*wait|wait\s*time)[^0-9]{0,25}([0-9]+\s*(?:시간|분|초|hours?|hrs?|minutes?|mins?|seconds?|secs?)(?:\s*[0-9]+\s*(?:분|초|minutes?|mins?|seconds?|secs?))?)/i;
  var CHALLENGE_TEXT_RE = /just\s*a\s*moment|checking\s*your\s*browser|verify\s*you\s*are\s*human|보안\s*확인|로봇이\s*아닙니다/i;

  function bigEnough(el) {
    var r = el.getBoundingClientRect();
    if (r.width < 40 || r.height < 40) return false;
    var cs = window.getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && cs.opacity !== '0';
  }

  function headText() {
    var parts = [document.title || ''];
    var hs = document.querySelectorAll('h1, h2, [role="heading"]');
    for (var i = 0; i < hs.length && i < 6; i++) parts.push(hs[i].innerText || hs[i].textContent || '');
    return parts.join(' ');
  }

  function detect() {
    var els = document.querySelectorAll(CAPTCHA_SEL);
    for (var i = 0; i < els.length; i++) {
      var src = els[i].getAttribute('src') || '';
      if (/size=invisible/.test(src)) continue;          // 보이지 않는 reCAPTCHA v3 배지 제외
      if (bigEnough(els[i])) return 'captcha';
    }
    if (/\/challenge(\/|$|\?)/i.test(location.pathname)) return 'captcha';
    var head = headText();
    if (CHALLENGE_TEXT_RE.test(head)) return 'captcha';
    if (QUEUE_HOST_RE.test(location.hostname) || QUEUE_PATH_RE.test(location.pathname)) return 'queue';
    if (QUEUE_TEXT_RE.test(head)) return 'queue';
    return 'none';
  }

  function queueInfo() {
    var t = (document.body && (document.body.innerText || document.body.textContent) || '').slice(0, 20000);
    var parts = [];
    var m = POS_RE.exec(t) || POS_RE2.exec(t);
    if (m) parts.push('앞에 ' + m[1] + '명');
    var e = ETA_RE.exec(t);
    if (e) parts.push('예상 ' + e[1].replace(/\s+/g, ' '));
    return parts.join(' · ');
  }

  var last = null;
  function tick() {
    var g, info = '';
    try {
      g = detect();
      if (g === 'queue') info = queueInfo();
    } catch (e) { return; }
    var key = g + '|' + info;
    if (key === last) return;
    last = key;
    try {
      var p = H.postMessage({ type: 'gate', kind: g, info: info, url: location.href });
      if (p && p.catch) p.catch(function () {});
    } catch (e) {}
  }

  tick();
  setInterval(tick, 1000);
})();
"""##
}
