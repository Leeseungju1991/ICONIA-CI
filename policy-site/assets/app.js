/* =========================================================================
   (주)숨코리아 정책 안내 — SPA router + markdown loader
   ========================================================================= */

(() => {
  'use strict';

  // 정책 id → markdown 파일 + 표시 제목
  const DOCS = {
    'terms':           { file: 'content/terms.md',           title: '이용약관' },
    'privacy':         { file: 'content/privacy.md',         title: '개인정보 처리방침' },
    'ai-disclosure':   { file: 'content/ai-disclosure.md',   title: 'AI 이용 안내' },
    'device':          { file: 'content/device.md',          title: '기기 연결·데이터 안내' },
    'commerce':        { file: 'content/commerce.md',        title: '커머스 안내' },
    'marketing':       { file: 'content/marketing.md',       title: '마케팅 정보 수신 동의' },
  };

  // 캐시
  const cache = new Map();

  // 요소
  const elNav = document.getElementById('site-nav');
  const elToggle = document.querySelector('.nav-toggle');
  const elHomeHero = document.querySelector('.hero[data-route="home"]');
  const elHomeGrid = document.querySelector('.policy-grid[data-route="home"]');
  const elDoc = document.querySelector('.doc[data-route="doc"]');
  const elContact = document.querySelector('.doc[data-route="contact"]');
  const elDocTitleBc = document.getElementById('doc-title-bc');
  const elDocBody = document.getElementById('doc-body');
  const elYear = document.getElementById('copy-year');

  if (elYear) elYear.textContent = new Date().getFullYear();

  // ─── Hash router ────────────────────────────────────────────────────
  function parseRoute() {
    // #/ , #/terms , #/contact ...
    const h = location.hash || '#/';
    const m = h.match(/^#\/?([\w-]*)$/);
    return m ? (m[1] || 'home') : 'home';
  }

  function setActiveNav(routeId) {
    elNav.querySelectorAll('a[data-doc]').forEach(a => {
      const id = a.getAttribute('data-doc');
      if (id === routeId || (id === 'home' && routeId === '')) {
        a.classList.add('is-active');
      } else {
        a.classList.remove('is-active');
      }
    });
  }

  function showHome() {
    if (elHomeHero) elHomeHero.hidden = false;
    if (elHomeGrid) elHomeGrid.hidden = false;
    if (elDoc) elDoc.hidden = true;
    if (elContact) elContact.hidden = true;
    document.title = '(주)숨코리아 — 정책 안내';
    window.scrollTo({ top: 0, behavior: 'instant' });
  }

  function showContact() {
    if (elHomeHero) elHomeHero.hidden = true;
    if (elHomeGrid) elHomeGrid.hidden = true;
    if (elDoc) elDoc.hidden = true;
    if (elContact) elContact.hidden = false;
    document.title = '회사 정보 / 문의 — (주)숨코리아';
    window.scrollTo({ top: 0, behavior: 'instant' });
  }

  async function showDoc(id) {
    const meta = DOCS[id];
    if (!meta) { showHome(); return; }
    if (elHomeHero) elHomeHero.hidden = true;
    if (elHomeGrid) elHomeGrid.hidden = true;
    if (elContact) elContact.hidden = true;
    if (elDoc) elDoc.hidden = false;
    if (elDocTitleBc) elDocTitleBc.textContent = meta.title;
    document.title = `${meta.title} — (주)숨코리아`;

    if (elDocBody) {
      elDocBody.innerHTML = '<p style="color:#888;">불러오는 중…</p>';
      try {
        const md = await loadMarkdown(meta.file);
        // marked.js — defer 로딩되므로 확인
        if (typeof marked === 'undefined') {
          await new Promise(r => {
            const check = setInterval(() => {
              if (typeof marked !== 'undefined') { clearInterval(check); r(); }
            }, 30);
            setTimeout(() => { clearInterval(check); r(); }, 3000);
          });
        }
        if (typeof marked === 'undefined') {
          // fallback — markdown 을 <pre> 로 표시
          const pre = document.createElement('pre');
          pre.textContent = md;
          elDocBody.innerHTML = '';
          elDocBody.appendChild(pre);
        } else {
          marked.setOptions({ gfm: true, breaks: false, headerIds: true });
          elDocBody.innerHTML = marked.parse(md);
          // 외부 링크 새 탭
          elDocBody.querySelectorAll('a[href^="http"]').forEach(a => {
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
          });
        }
      } catch (err) {
        elDocBody.innerHTML = `<div class="doc-status-bar">문서를 불러오지 못했습니다 (${meta.file}). 새로고침해 주세요.</div>`;
        console.error('load failed:', err);
      }
    }

    window.scrollTo({ top: 0, behavior: 'instant' });
  }

  async function loadMarkdown(path) {
    if (cache.has(path)) return cache.get(path);
    const res = await fetch(path, { cache: 'no-cache' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const text = await res.text();
    cache.set(path, text);
    return text;
  }

  function route() {
    const id = parseRoute();
    setActiveNav(id);
    // 모바일 nav 닫기
    if (elNav.classList.contains('is-open')) {
      elNav.classList.remove('is-open');
      if (elToggle) elToggle.setAttribute('aria-expanded', 'false');
    }
    if (id === 'home' || id === '') return showHome();
    if (id === 'contact') return showContact();
    return showDoc(id);
  }

  // ─── Mobile nav toggle ──────────────────────────────────────────────
  if (elToggle) {
    elToggle.addEventListener('click', () => {
      const isOpen = elNav.classList.toggle('is-open');
      elToggle.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
    });
  }

  // ─── Init ───────────────────────────────────────────────────────────
  window.addEventListener('hashchange', route);
  // 첫 진입 시 marked 가 아직 로드 안 됐을 수 있음 → defer 후 route
  if (document.readyState === 'complete') {
    route();
  } else {
    window.addEventListener('load', route);
  }
})();
