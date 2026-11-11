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

  function report(json) {
    if (json && hasErrors(json, 0)) return;
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
