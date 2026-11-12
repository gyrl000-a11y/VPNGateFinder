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
