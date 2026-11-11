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
