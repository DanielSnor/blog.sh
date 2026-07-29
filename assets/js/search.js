(function () {
  var escapeHtml = window.Blog.escapeHtml;
  var i18n = window.BLOG_I18N || {};

  function fold(s) {
    return (s || '').normalize('NFKD').replace(/\p{Mn}/gu, '').toLowerCase().replace(/\s+/g, ' ').trim();
  }

  // Text in "quotes" (including typographic ones) = one phrase, otherwise a
  // word; an optional leading "-" excludes it. Everything is folded (NFKD,
  // no diacritics, lowercase).
  function parseQueryTokens(raw) {
    var tokens = [];
    var re = /(-?)(?:["„“”]([^"„“”]+)["„“”]|(\S+))/g;
    var m;
    while ((m = re.exec(raw || '')) !== null) {
      var t = fold(m[2] != null ? m[2] : m[3]).trim().replace(/\s+/g, ' ');
      if (t) tokens.push({ t: t, neg: m[1] === '-' });
    }
    return tokens;
  }

  // AND: an entry matches only if it contains every positive word/phrase and
  // none of the excluded (-) ones.
  function searchRank(list, tokens) {
    var pos = tokens.filter(function (x) { return !x.neg; });
    var neg = tokens.filter(function (x) { return x.neg; });
    var hits = [];
    if (!pos.length) return hits;
    for (var i = 0; i < list.length; i++) {
      var f = list[i].folded;
      if (!f) continue;
      var ok = true;
      for (var k = 0; k < pos.length; k++) { if (f.indexOf(pos[k].t) === -1) { ok = false; break; } }
      if (ok) { for (var n = 0; n < neg.length; n++) { if (f.indexOf(neg[n].t) !== -1) { ok = false; break; } } }
      if (ok) hits.push(list[i]);
    }
    return hits;
  }

  function resultsUnit(n) {
    if (n === 1) return i18n.results_one;
    if (n < 5) return i18n.results_few;
    return i18n.results_many;
  }

  function renderResults(container, hits, query, archivePending) {
    if (!query.trim()) {
      container.innerHTML = '<p class="search-status">' + escapeHtml(i18n.search_prompt || '') + '</p>';
      return;
    }
    var archiveNote = archivePending ? ' <span class="search-archive-pending">' + i18n.searching_archive + '</span>' : '';
    if (!hits.length) {
      var noResults = archivePending
        ? i18n.no_results_pending + archiveNote
        : i18n.no_results_final + archiveNote + i18n.try_other_words;
      container.innerHTML = '<p class="search-status">' + noResults + '</p>';
      return;
    }
    var html = '<p class="search-status">' + hits.length + ' ' + resultsUnit(hits.length) + archiveNote + '</p>';
    html += hits.map(function (p) {
      var title = p.title || (p.excerpt.length > 60 ? p.excerpt.slice(0, 60) + '…' : p.excerpt);
      return (
        '<div class="card post-list-item search-result">' +
          '<p class="meta">' + escapeHtml(p.date) + '</p>' +
          '<h2><a href="' + escapeHtml(p.url) + '">' + escapeHtml(title) + '</a></h2>' +
          '<p>' + escapeHtml(p.excerpt) + '</p>' +
        '</div>'
      );
    }).join('');
    container.innerHTML = html;
  }

  document.addEventListener('DOMContentLoaded', function () {
    var input = document.getElementById('search-q');
    var results = document.getElementById('search-results');
    var heading = document.getElementById('search-heading');
    if (!input) return;

    var q = new URLSearchParams(window.location.search).get('q') || '';
    if (results) input.value = q;
    if (heading && q.trim()) heading.textContent = i18n.search_prefix + q;
    if (!results) return; // outside /search/, let the form submit natively

    // The index is fetched in two batches: recent (search-index.json) right
    // when the page opens, archive (search-index-archive.json) only on the
    // first real query -- so /search/ doesn't wait on the whole,
    // ever-growing archive when the visitor is searching for something from
    // the last few hundred articles. The build does this split in
    // build_blog.rb (SEARCH_INDEX_RECENT_LIMIT).
    var index = null;
    var archiveIndex = null;
    var archiveState = 'idle'; // idle -> loading -> loaded | failed
    var pending = null;

    function combinedIndex() {
      return archiveIndex ? index.concat(archiveIndex) : index;
    }

    function loadArchiveIfNeeded(query) {
      if (archiveState !== 'idle' || !query.trim()) return;
      archiveState = 'loading';
      fetch('/search-index-archive.json')
        .then(function (r) { return r.json(); })
        .then(function (data) {
          archiveIndex = data;
          archiveState = 'loaded';
          run();
        })
        .catch(function () { archiveState = 'failed'; });
    }

    function run() {
      if (!index) return;
      var query = input.value;
      loadArchiveIfNeeded(query);
      if (heading) heading.textContent = query.trim() ? i18n.search_prefix + query : i18n.search_heading;
      renderResults(results, searchRank(combinedIndex(), parseQueryTokens(query)), query, archiveState === 'loading');
    }

    results.innerHTML = '<p class="search-status">' + escapeHtml(i18n.loading_index) + '</p>';
    fetch('/search-index.json')
      .then(function (r) { return r.json(); })
      .then(function (data) { index = data; run(); })
      .catch(function () {
        results.innerHTML = '<p class="search-status">' + escapeHtml(i18n.index_unavailable) + '</p>';
      });

    input.addEventListener('input', function () {
      clearTimeout(pending);
      pending = setTimeout(run, 150);
    });
  });
})();
