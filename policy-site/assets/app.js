/* =========================================================================
   ICONIA · 숨코리아 — SPA router + markdown loader + snackbar + dropdown nav
   ========================================================================= */

(() => {
  'use strict';

  // 정책 id → markdown 파일 + 표시 제목
  const DOCS = {
    'usage-guide':   { file: 'content/usage-guide.md',   title: '앱 사용 가이드' },
    'terms':         { file: 'content/terms.md',         title: '이용약관' },
    'privacy':       { file: 'content/privacy.md',       title: '개인정보 처리방침' },
    'ai-disclosure': { file: 'content/ai-disclosure.md', title: 'AI 이용 안내' },
    'device':        { file: 'content/device.md',        title: '기기 연결·데이터 안내' },
    'commerce':      { file: 'content/commerce.md',      title: '커머스 소개' },
    'marketing':     { file: 'content/marketing.md',     title: '마케팅 정보 수신 동의' },
  };

  // 각 doc id가 어느 nav-group에 속하는지
  const GROUP_MAP = {
    'terms':         'policy',
    'privacy':       'policy',
    'ai-disclosure': 'howto',
    'marketing':     'policy',
    'commerce':      'policy',
    'device':        'howto',
    'usage-guide':   'howto',
    'download':      'howto',
    'how-install':   'howto',
  };

  // 다운로드 파일 (사용자가 추후 첨부)
  // 예: android: 'assets/iconia-latest.apk'
  const DOWNLOADS = {
    android: null,  // 'assets/iconia-latest.apk' 형태로 채워주세요
    ios:     null,  // 'assets/iconia-latest.ipa'
  };

  const SNACKBAR_TIMEOUT = 3200;

  // 캐시
  const cache = new Map();

  // 요소
  const elNav    = document.getElementById('site-nav');
  const elToggle = document.querySelector('.nav-toggle');
  const elHome   = document.querySelector('.page-home[data-route="home"]');
  const elDoc    = document.querySelector('.doc[data-route="doc"]');
  const elContact = document.querySelector('.doc[data-route="contact"]');
  const elDocTitleBc = document.getElementById('doc-title-bc');
  const elDocBody = document.getElementById('doc-body');
  const elYear   = document.getElementById('copy-year');
  const elSnack  = document.getElementById('snackbar');

  if (elYear) elYear.textContent = new Date().getFullYear();

  // ─── Snackbar ───────────────────────────────────────────────────────
  let snackTimer = null;
  function snackbar(message) {
    if (!elSnack) return;
    elSnack.textContent = message;
    elSnack.classList.add('is-visible');
    if (snackTimer) clearTimeout(snackTimer);
    snackTimer = setTimeout(() => {
      elSnack.classList.remove('is-visible');
    }, SNACKBAR_TIMEOUT);
  }

  // ─── Hash router ────────────────────────────────────────────────────
  function parseRoute() {
    const h = location.hash || '#/';
    const m = h.match(/^#\/?([\w-]*)(?:#.*)?$/);
    return m ? (m[1] || 'home') : 'home';
  }

  function setActiveNav(routeId) {
    if (!elNav) return;

    // 모든 nav-item 및 드롭다운 링크 active 초기화
    elNav.querySelectorAll('.nav-item, .nav-dropdown a').forEach(a => {
      a.classList.remove('is-active');
    });
    // nav-group-btn active 초기화
    elNav.querySelectorAll('.nav-group-btn').forEach(btn => {
      btn.classList.remove('is-active');
    });

    // 홈
    if (routeId === 'home' || routeId === '') {
      const homeLink = elNav.querySelector('.nav-item[data-doc="home"]');
      if (homeLink) homeLink.classList.add('is-active');
      return;
    }

    // 해당 링크 active
    const activeLink = elNav.querySelector(`[data-doc="${routeId}"]`);
    if (activeLink) activeLink.classList.add('is-active');

    // 부모 그룹 버튼 active
    const groupId = GROUP_MAP[routeId];
    if (groupId) {
      const groupEl = elNav.querySelector(`.nav-group[data-group="${groupId}"] .nav-group-btn`);
      if (groupEl) groupEl.classList.add('is-active');
    }
  }

  function showHome() {
    if (elHome) elHome.hidden = false;
    if (elDoc) elDoc.hidden = true;
    if (elContact) elContact.hidden = true;
    document.title = 'ICONIA — 인형과 함께하는 새로운 일상';
    window.scrollTo({ top: 0, behavior: 'instant' });
  }

  function showContact() {
    if (elHome) elHome.hidden = true;
    if (elDoc) elDoc.hidden = true;
    if (elContact) elContact.hidden = false;
    document.title = '회사 정보 / 문의 — ICONIA';
    window.scrollTo({ top: 0, behavior: 'instant' });
  }

  async function showDoc(id) {
    const meta = DOCS[id];
    if (!meta) { showHome(); return; }
    if (elHome) elHome.hidden = true;
    if (elContact) elContact.hidden = true;
    if (elDoc) elDoc.hidden = false;
    if (elDocTitleBc) elDocTitleBc.textContent = meta.title;
    document.title = `${meta.title} — ICONIA`;

    if (elDocBody) {
      elDocBody.innerHTML = '<p style="color:#888;">불러오는 중…</p>';
      try {
        const md = await loadMarkdown(meta.file);
        if (typeof marked === 'undefined') {
          await new Promise(r => {
            const check = setInterval(() => {
              if (typeof marked !== 'undefined') { clearInterval(check); r(); }
            }, 30);
            setTimeout(() => { clearInterval(check); r(); }, 3000);
          });
        }
        if (typeof marked === 'undefined') {
          const pre = document.createElement('pre');
          pre.textContent = md;
          elDocBody.innerHTML = '';
          elDocBody.appendChild(pre);
        } else {
          marked.setOptions({ gfm: true, breaks: false, headerIds: true });
          elDocBody.innerHTML = marked.parse(md);
          elDocBody.querySelectorAll('a[href^="http"]').forEach(a => {
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
          });
          // 후처리: UI 컴포넌트 변환
          try {
            postProcessDoc(elDocBody, md);
          } catch (e) {
            console.warn('postProcessDoc error:', e);
          }
        }
      } catch (err) {
        elDocBody.innerHTML = `<div class="doc-status-bar">문서를 불러오지 못했습니다 (${meta.file}). 새로고침해 주세요.</div>`;
        console.error('load failed:', err);
      }
    }
    window.scrollTo({ top: 0, behavior: 'instant' });
  }

  // ─── 후처리: 마크다운 렌더 결과에 UI 컴포넌트 주입 ─────────────────
  function postProcessDoc(container, rawMd) {
    // 2) TL;DR 카드 — 💡로 시작하는 첫 blockquote 변환
    try {
      var firstBq = container.querySelector('blockquote');
      if (firstBq) {
        var bqText = firstBq.textContent || '';
        if (bqText.trim().startsWith('💡')) {
          var inner = firstBq.innerHTML;
          var tldrDiv = document.createElement('div');
          tldrDiv.className = 'tldr-card';
          var badge = '<span class="tldr-badge">&#10024; 핵심 요약</span>';
          // 💡 이모지 + "핵심 요약" 텍스트 라벨 제거 후 본문만 남기기
          inner = inner.replace(/^[\s\S]*?<\/p>/m, function(m) {
            return m
              .replace(/💡\s*/g, '')
              .replace(/\*\*핵심 요약\*\*\s*—?\s*/g, '')
              .replace(/<strong>핵심 요약<\/strong>\s*—?\s*/gi, '');
          });
          tldrDiv.innerHTML = badge + inner;
          firstBq.parentNode.replaceChild(tldrDiv, firstBq);
        }
      }
    } catch (e) { console.warn('tldr-card:', e); }

    // 3) 콜아웃 blockquote — ✅ ⚠️ ℹ️ 감지
    try {
      container.querySelectorAll('blockquote').forEach(function(bq) {
        var text = bq.textContent.trim();
        var cls = null;
        if (text.startsWith('✅')) cls = 'callout-success';
        else if (text.startsWith('⚠️') || text.startsWith('⚠')) cls = 'callout-warning';
        else if (text.startsWith('ℹ️') || text.startsWith('ℹ')) cls = 'callout-info';
        if (cls) {
          var div = document.createElement('div');
          div.className = cls;
          div.innerHTML = bq.innerHTML;
          bq.parentNode.replaceChild(div, bq);
        }
      });
    } catch (e) { console.warn('callout:', e); }

    // 4) h2 텍스트 그대로 (번호 뱃지·아이콘 미사용) — TOC 호환 위해 h2-text 래퍼만 유지
    try {
      container.querySelectorAll('h2').forEach(function(h2) {
        var origText = h2.textContent;
        h2.innerHTML = '<span class="h2-text">' + origText + '</span>';
      });
    } catch (e) { console.warn('h2-plain:', e); }

    // 5) 목차 (TOC) — 좌측 sticky sidebar + 스크롤 active 표시 + 진행 인디케이터
    try {
      var h2s = container.querySelectorAll('h2');
      var sidebar = document.getElementById('doc-sidebar');
      if (sidebar) sidebar.innerHTML = '';

      if (h2s.length > 1 && sidebar) {
        var tocWrap = document.createElement('nav');
        tocWrap.className = 'doc-toc-sidebar';
        tocWrap.setAttribute('aria-label', '목차');

        var tocHead = document.createElement('button');
        tocHead.type = 'button';
        tocHead.className = 'doc-toc-head';
        tocHead.setAttribute('aria-expanded', 'true');
        tocHead.setAttribute('aria-controls', 'doc-toc-items');
        tocHead.innerHTML =
          '<span class="doc-toc-icon" aria-hidden="true">' +
            '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">' +
              '<path d="M3 4h10"/><path d="M3 8h10"/><path d="M3 12h7"/>' +
            '</svg>' +
          '</span>' +
          '<span class="doc-toc-title">목차</span>' +
          '<span class="doc-toc-count">' + h2s.length + '</span>' +
          '<span class="doc-toc-toggle" aria-hidden="true">' +
            '<svg viewBox="0 0 12 8" width="12" height="8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M1 1.5l5 5 5-5"/></svg>' +
          '</span>';

        // 접기/펼치기 토글
        tocHead.addEventListener('click', function() {
          var collapsed = tocWrap.classList.toggle('is-collapsed');
          tocHead.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
        });

        var itemsWrap = document.createElement('ol');
        itemsWrap.className = 'doc-toc-items';
        itemsWrap.id = 'doc-toc-items';

        var progressBar = null;
        var links = [];

        h2s.forEach(function(h2, idx) {
          var chipId = 'toc-h2-' + idx;
          if (!h2.id) h2.id = chipId;
          var labelText = h2.querySelector('.h2-text')
            ? h2.querySelector('.h2-text').textContent
            : h2.textContent;
          var numM = labelText.match(/^(\d[\d\-]*)/);
          var chipNum = numM ? numM[1] : (idx + 1);
          var labelOnly = labelText
            .replace(/^\d[\d\-]*번?\s*항목?\s*—?\s*/, '')
            .split('—')[0]
            .trim();

          // 하위 항목 판정 — "8-2", "10-2" 같이 하이픈 포함된 번호면 sub
          var isSub = typeof chipNum === 'string' && chipNum.indexOf('-') !== -1;

          var li = document.createElement('li');
          li.className = 'doc-toc-item' + (isSub ? ' is-sub' : '');
          if (isSub) {
            li.dataset.parentNum = String(chipNum).split('-')[0];
          } else {
            li.dataset.tocNum = String(chipNum);
          }
          var link = document.createElement('a');
          link.className = 'doc-toc-link';
          link.href = '#' + h2.id;
          link.dataset.h2Id = h2.id;
          link.innerHTML =
            '<span class="doc-toc-num">' + chipNum + '</span>' +
            '<span class="doc-toc-label">' + labelOnly + '</span>';
          link.addEventListener('click', function(e) {
            e.preventDefault();
            var target = document.getElementById(h2.id);
            if (target) {
              var hdrOffset = 80;
              var y = target.getBoundingClientRect().top + window.pageYOffset - hdrOffset;
              window.scrollTo({ top: y, behavior: 'smooth' });
            }
          });
          li.appendChild(link);
          itemsWrap.appendChild(li);
          links.push({ link: link, h2: h2 });
        });

        // 부모-자식 관계 마킹 + 부모에 펼침 토글 추가 (sub 기본 접힘)
        var parentMap = {}; // parentNum -> { li, children: [li...] }
        Array.prototype.forEach.call(itemsWrap.children, function(li) {
          if (li.classList.contains('is-sub')) {
            var pn = li.dataset.parentNum;
            if (parentMap[pn]) parentMap[pn].children.push(li);
          } else {
            parentMap[li.dataset.tocNum] = { li: li, children: [] };
          }
        });

        Object.keys(parentMap).forEach(function(num) {
          var entry = parentMap[num];
          if (!entry.children.length) return;
          entry.li.classList.add('has-children');
          var link = entry.li.querySelector('.doc-toc-link');
          var btn = document.createElement('button');
          btn.type = 'button';
          btn.className = 'doc-toc-expand';
          btn.setAttribute('aria-expanded', 'false');
          btn.setAttribute('aria-label', '하위 항목 펼치기');
          btn.innerHTML =
            '<svg viewBox="0 0 10 10" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M3.5 2l3 3-3 3"/></svg>';
          btn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            toggleParent(entry, !entry.li.classList.contains('is-expanded'));
          });
          link.appendChild(btn);
        });

        // toggleParent 헬퍼 — 부모/자식 열고닫기
        function toggleParent(entry, open) {
          if (open) {
            entry.li.classList.add('is-expanded');
            entry.children.forEach(function(c) { c.classList.add('is-shown'); });
          } else {
            entry.li.classList.remove('is-expanded');
            entry.children.forEach(function(c) { c.classList.remove('is-shown'); });
          }
          var btn = entry.li.querySelector('.doc-toc-expand');
          if (btn) btn.setAttribute('aria-expanded', open ? 'true' : 'false');
        }

        // 외부에서 호출 가능하도록 노출
        tocWrap.__tocParentMap = parentMap;
        tocWrap.__tocToggleParent = toggleParent;

        tocWrap.appendChild(tocHead);
        tocWrap.appendChild(itemsWrap);
        sidebar.appendChild(tocWrap);

        // ─ IntersectionObserver 로 active section 추적 ─
        setupTocActiveObserver(links, progressBar, itemsWrap);
      }
    } catch (e) { console.warn('toc:', e); }

    // 5b) 선택적 섹션 자동 접기/펼치기 — 키워드 매칭되는 h2 섹션을 <details> 로 감쌈
    try {
      var optionalKeywords = ['부록', '참고', '심화', '기타', '더 알아보기', '추가 안내', '부가 설명'];
      var allH2 = Array.prototype.slice.call(container.querySelectorAll('h2'));
      allH2.forEach(function(h2) {
        var txt = (h2.querySelector('.h2-text') ? h2.querySelector('.h2-text').textContent : h2.textContent) || '';
        var match = optionalKeywords.some(function(k) { return txt.indexOf(k) !== -1; });
        if (!match) return;
        // 같은 부모 안에서 다음 h2 전까지의 형제들을 details 로 감싸기
        var details = document.createElement('details');
        details.className = 'doc-collapsible';
        var summary = document.createElement('summary');
        summary.className = 'doc-collapsible-summary';
        summary.innerHTML =
          '<span class="doc-collapsible-icon" aria-hidden="true">&#9656;</span>' +
          '<span class="doc-collapsible-label">' + txt + '</span>' +
          '<span class="doc-collapsible-hint">펼쳐 보기</span>';
        details.appendChild(summary);
        // h2 다음부터 다음 h2 전까지의 모든 형제를 details 안으로 이동
        var sibs = [];
        var sib = h2.nextSibling;
        while (sib) {
          if (sib.nodeType === 1 && sib.tagName === 'H2') break;
          sibs.push(sib);
          sib = sib.nextSibling;
        }
        sibs.forEach(function(s) { details.appendChild(s); });
        // h2 자리에 details 끼워넣고 h2 제거
        h2.parentNode.replaceChild(details, h2);
        // 열림 토글 시 summary 텍스트 변경
        details.addEventListener('toggle', function() {
          var hint = summary.querySelector('.doc-collapsible-hint');
          if (hint) hint.textContent = details.open ? '접기' : '펼쳐 보기';
        });
      });
    } catch (e) { console.warn('collapsible:', e); }

    // 6) 모바일 테이블 카드용 data-label 주입
    try {
      container.querySelectorAll('table').forEach(function(tbl) {
        var headers = Array.from(tbl.querySelectorAll('th')).map(function(th) {
          return th.textContent.trim();
        });
        if (!headers.length) return;
        tbl.querySelectorAll('tbody tr').forEach(function(tr) {
          tr.querySelectorAll('td').forEach(function(td, ci) {
            if (headers[ci]) td.setAttribute('data-label', headers[ci]);
          });
        });
      });
    } catch (e) { console.warn('table-mobile:', e); }

    // 7) 이메일·코드 클릭 복사
    try {
      container.querySelectorAll('code').forEach(function(code) {
        var text = code.textContent.trim();
        if (!text || code.closest('pre')) return;
        code.title = '클릭하면 복사됩니다';
        code.addEventListener('click', function() {
          copyToClipboard(text, '복사되었습니다: ' + text);
        });
      });
      // 이메일 링크 복사
      container.querySelectorAll('a[href^="mailto:"]').forEach(function(a) {
        var email = a.textContent.trim();
        a.classList.add('copyable');
        a.addEventListener('click', function(e) {
          e.preventDefault();
          copyToClipboard(email, '이메일이 복사되었습니다');
        });
      });
    } catch (e) { console.warn('copy:', e); }

    // 8) privacy 10번 항목 — 보호책임자 테이블을 contact-officer-card 로 변환
    try {
      container.querySelectorAll('h2').forEach(function(h2) {
        var txt = h2.textContent || '';
        if (txt.indexOf('10번') !== -1 && txt.indexOf('회사 정보') !== -1) {
          var tbl = h2.nextElementSibling;
          while (tbl && tbl.tagName !== 'TABLE') tbl = tbl.nextElementSibling;
          if (tbl) {
            var card = document.createElement('div');
            card.className = 'contact-officer-card';
            var cardTitle = document.createElement('div');
            cardTitle.className = 'card-title';
            cardTitle.innerHTML = '<span>&#128274;</span> 개인정보 보호책임자 / 회사 연락처';
            var dl = document.createElement('dl');
            tbl.querySelectorAll('tbody tr').forEach(function(tr) {
              var cells = tr.querySelectorAll('td');
              if (cells.length >= 2) {
                var dt = document.createElement('dt');
                dt.textContent = cells[0].textContent.trim();
                var dd = document.createElement('dd');
                dd.innerHTML = cells[1].innerHTML;
                dl.appendChild(dt);
                dl.appendChild(dd);
              }
            });
            card.appendChild(cardTitle);
            card.appendChild(dl);
            tbl.parentNode.replaceChild(card, tbl);
          }
        }
      });
    } catch (e) { console.warn('officer-card:', e); }
  }

  // ─── TOC sidebar active section 추적 (IntersectionObserver) ──────────
  var tocObserver = null;
  function setupTocActiveObserver(links, progressBar, itemsWrap) {
    try {
      if (tocObserver) { tocObserver.disconnect(); tocObserver = null; }
      if (!('IntersectionObserver' in window)) return;

      var idToLink = {};
      links.forEach(function(p) { idToLink[p.h2.id] = p.link; });

      function setActive(h2Id) {
        Object.keys(idToLink).forEach(function(k) {
          idToLink[k].classList.remove('is-active');
        });
        var active = idToLink[h2Id];
        if (active) {
          active.classList.add('is-active');
          // active 가 sub(8-1 등) 라면 부모를 자동 펼치기
          var activeLi = active.parentElement;
          if (activeLi && activeLi.classList.contains('is-sub')) {
            var parentNum = activeLi.dataset.parentNum;
            var tocWrap = itemsWrap && itemsWrap.parentElement;
            if (parentNum && tocWrap && tocWrap.__tocParentMap && tocWrap.__tocToggleParent) {
              var entry = tocWrap.__tocParentMap[parentNum];
              if (entry && !entry.li.classList.contains('is-expanded')) {
                tocWrap.__tocToggleParent(entry, true);
              }
            }
          }
          // 진행 인디케이터 dot 이동
          if (progressBar) {
            var aLi = active.parentElement;
            var top = aLi.offsetTop + aLi.offsetHeight / 2 - 6; // dot 가운데 정렬
            var dot = progressBar.querySelector('.doc-toc-progress-dot');
            if (dot) dot.style.transform = 'translateY(' + top + 'px)';
          }
          // 사이드바 자체 스크롤도 active 항목 보이도록
          if (itemsWrap) {
            var liEl = active.parentElement;
            var sb = itemsWrap.parentElement; // sidebar nav
            var liTop = liEl.offsetTop;
            var liH = liEl.offsetHeight;
            var sbH = sb.clientHeight;
            var sbScroll = sb.scrollTop;
            if (liTop < sbScroll + 20 || liTop + liH > sbScroll + sbH - 20) {
              sb.scrollTo({ top: Math.max(0, liTop - sbH / 2), behavior: 'smooth' });
            }
          }
        }
      }

      // 가장 최근에 viewport top 부근에 진입한 h2를 active로
      var visibleMap = {};
      tocObserver = new IntersectionObserver(function(entries) {
        entries.forEach(function(e) {
          visibleMap[e.target.id] = e.intersectionRatio;
        });
        // 화면 상단 100px ~ 40% 사이를 active 기준선으로 — 가장 위에 있는 visible h2 선택
        var visibleH2s = links
          .map(function(p) { return p.h2; })
          .filter(function(h) {
            var r = h.getBoundingClientRect();
            return r.bottom > 80 && r.top < window.innerHeight * 0.5;
          })
          .sort(function(a, b) { return a.getBoundingClientRect().top - b.getBoundingClientRect().top; });
        if (visibleH2s.length) {
          setActive(visibleH2s[0].id);
        } else {
          // 화면 위쪽으로 모두 지나갔다면 마지막 지난 h2를 active
          var passed = links
            .map(function(p) { return p.h2; })
            .filter(function(h) { return h.getBoundingClientRect().top < 80; });
          if (passed.length) setActive(passed[passed.length - 1].id);
        }
      }, {
        rootMargin: '-80px 0px -40% 0px',
        threshold: [0, 0.1, 0.5, 1],
      });

      links.forEach(function(p) { tocObserver.observe(p.h2); });

      // 초기 active
      setTimeout(function() {
        if (links[0]) setActive(links[0].h2.id);
      }, 100);
    } catch (e) { console.warn('toc-observer:', e); }
  }

  function copyToClipboard(text, message) {
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function() {
          snackbar(message);
        }).catch(function() {
          fallbackCopy(text, message);
        });
      } else {
        fallbackCopy(text, message);
      }
    } catch (e) { console.warn('clipboard:', e); }
  }

  function fallbackCopy(text, message) {
    try {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.focus(); ta.select();
      document.execCommand('copy');
      ta.remove();
      snackbar(message);
    } catch (e) { console.warn('fallbackCopy:', e); }
  }

  async function loadMarkdown(path) {
    if (cache.has(path)) return cache.get(path);
    const res = await fetch(path, { cache: 'no-cache' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const text = await res.text();
    cache.set(path, text);
    return text;
  }

  function closeAllDropdowns() {
    if (!elNav) return;
    elNav.querySelectorAll('.nav-group.is-open').forEach(g => {
      g.classList.remove('is-open');
      const btn = g.querySelector('.nav-group-btn');
      if (btn) btn.setAttribute('aria-expanded', 'false');
    });
    // :focus-within 으로 인한 잔존 방지 — nav 내부 포커스 해제
    if (elNav.contains(document.activeElement) && document.activeElement.blur) {
      document.activeElement.blur();
    }
  }

  function route() {
    const id = parseRoute();
    setActiveNav(id);
    // 모바일 메뉴 닫기
    if (elNav && elNav.classList.contains('is-open')) {
      elNav.classList.remove('is-open');
      if (elToggle) elToggle.setAttribute('aria-expanded', 'false');
    }
    // 데스크탑 드롭다운 닫기 (+ focus 해제)
    closeAllDropdowns();

    if (id === 'home' || id === '') return showHome();
    if (id === 'contact') return showContact();
    // download / how-install → 홈 스크롤 앵커
    if (id === 'download' || id === 'how-install') return showHome();
    return showDoc(id);
  }

  // ─── Mobile nav toggle ──────────────────────────────────────────────
  if (elToggle) {
    elToggle.addEventListener('click', () => {
      const isOpen = elNav.classList.toggle('is-open');
      elToggle.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
    });
  }

  // ─── Dropdown nav: 모바일 아코디언 + 데스크탑 키보드 ──────────────
  if (elNav) {
    elNav.querySelectorAll('.nav-group-btn').forEach(btn => {
      const group = btn.closest('.nav-group');

      btn.addEventListener('click', (e) => {
        const isMobile = window.innerWidth <= 1080;
        if (!isMobile) return; // 데스크탑은 CSS :hover로 처리

        e.stopPropagation();
        const wasOpen = group.classList.contains('is-open');
        // 다른 그룹 닫기
        closeAllDropdowns();
        if (!wasOpen) {
          group.classList.add('is-open');
          btn.setAttribute('aria-expanded', 'true');
        }
      });

      // 키보드 접근성: Enter / Space
      btn.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          btn.click();
        }
        if (e.key === 'Escape') {
          group.classList.remove('is-open');
          btn.setAttribute('aria-expanded', 'false');
          btn.focus();
        }
      });
    });

    // 드롭다운 내 링크에서 Escape 시 닫기
    elNav.querySelectorAll('.nav-dropdown a').forEach(link => {
      link.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
          const group = link.closest('.nav-group');
          if (group) {
            group.classList.remove('is-open');
            const btn = group.querySelector('.nav-group-btn');
            if (btn) { btn.setAttribute('aria-expanded', 'false'); btn.focus(); }
          }
        }
      });
      // 클릭 시: 즉시 blur 해서 :focus-within 잔존 방지
      link.addEventListener('click', () => {
        if (link.blur) link.blur();
        closeAllDropdowns();
      });
    });
  }

  // 외부 클릭 시 드롭다운 닫기 (데스크탑에서는 :hover로 처리되지만 안전장치)
  document.addEventListener('click', (e) => {
    if (elNav && !elNav.contains(e.target)) {
      closeAllDropdowns();
    }
  });

  // ─── Download buttons ───────────────────────────────────────────────
  document.querySelectorAll('[data-download]').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      const os = btn.getAttribute('data-download');
      const url = DOWNLOADS[os];
      if (url) {
        const a = document.createElement('a');
        a.href = url;
        a.download = '';
        document.body.appendChild(a);
        a.click();
        a.remove();
        snackbar(`${os === 'android' ? 'Android (APK)' : 'iOS (IPA)'} 다운로드를 시작합니다…`);
      } else {
        const osLabel = os === 'android' ? 'Android (APK)' : 'iOS (IPA)';
        snackbar(`${osLabel}는 현재 출시 준비중입니다. 곧 만나뵙겠습니다!`);
      }
    });
  });

  // ─── Init ───────────────────────────────────────────────────────────
  window.addEventListener('hashchange', route);
  if (document.readyState === 'complete') {
    route();
  } else {
    window.addEventListener('load', route);
  }
})();
