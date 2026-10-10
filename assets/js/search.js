(function () {
  var escapeHtml = window.Blog.escapeHtml;
  var i18n = window.BLOG_I18N || {};

  // How many result cards are drawn at most. See renderResults for why there
  // is a ceiling at all, and rankHits for why fifty of four thousand is a
  // fair answer rather than an arbitrary truncation.
  var RESULT_LIMIT = 50;

  // The transliteration table and the whole pipeline mirror Slug.fold in
  // lib/slug.rb -- the index was folded server-side, so any drift between
  // the two silently breaks matching. Change them together.
  var FOLD_MAP = {
    'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'ø': 'o', 'đ': 'd',
    'ð': 'd', 'þ': 'th', 'ł': 'l', 'ħ': 'h', 'ŧ': 't',
    'ŋ': 'n', 'ı': 'i',
    // Same table as lib/slug.rb, and it has to stay the same: a final
    // sigma is the same letter as the one in the middle of a word.
    'ς': 'σ'
  };

  function fold(s) {
    return (s || '').normalize('NFKD').replace(/\p{Mn}/gu, '').toLowerCase()
      .replace(/[ßæœøđðþłħŧŋıς]/g, function (ch) { return FOLD_MAP[ch]; })
      // ASCII whitespace only, the way Ruby's \s is: a zero-width no-break
      // space or a line separator inside a title would otherwise collapse
      // here and not there, and the two folds would disagree again.
      .replace(/[ \t\n\r\f\v]+/g, ' ').trim();
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
  function searchMatches(list, tokens) {
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

  function escapeRe(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  // Ranking. The index carries one folded blob per entry -- title, text and
  // tags run together -- so all the filter above can say is that the words
  // are in there somewhere. Which is why results used to arrive in index
  // order: a post whose title IS the query sat wherever its date put it,
  // behind everything that had merely mentioned the word in passing.
  //
  // The score is small enough to say in a sentence. A word in the title
  // counts for more than a word in the text, and a whole word counts for
  // more than the same letters inside a longer one -- "art" in "start" is
  // not what anybody meant. Every hit already contains every term, so the
  // question is never whether a post matches, only how squarely.
  //
  // Ties keep the order they arrived in, which is newest first: sort is
  // stable, and among equally good answers the recent one is the better
  // guess on a personal archive. So chronology is still what decides --
  // it just no longer decides everything.
  var TITLE_WORD = 10, TITLE_PART = 6, TEXT_WORD = 3, TEXT_PART = 1;

  function rankHits(hits, tokens) {
    var words = tokens.filter(function (x) { return !x.neg; }).map(function (x) {
      // A "word" here ends where letters and digits do, in any script --
      // the folded text keeps Greek and Cyrillic, and \b would call the
      // boundary in the wrong place in both.
      return { t: x.t, re: new RegExp('(?:^|[^\\p{L}\\p{N}])' + escapeRe(x.t) + '(?:$|[^\\p{L}\\p{N}])', 'u') };
    });

    return hits.map(function (p) {
      // Folded once per entry and kept: the same objects are searched again
      // on every keystroke, and folding is the expensive part of all this.
      if (p.tfold === undefined) p.tfold = fold(p.title || '');
      var score = 0;
      for (var k = 0; k < words.length; k++) {
        var w = words[k];
        if (p.tfold.indexOf(w.t) !== -1) score += w.re.test(p.tfold) ? TITLE_WORD : TITLE_PART;
        else score += w.re.test(p.folded) ? TEXT_WORD : TEXT_PART;
      }
      return { post: p, score: score };
    }).sort(function (a, b) {
      return b.score - a.score;
    }).map(function (x) { return x.post; });
  }

  // Why a result is in the list, shown on the result: the words that were
  // asked for are marked where the card shows them. The search folds
  // everything -- "ctyri" finds "Čtyři" -- so the page cannot look the
  // query up in the text as written; it folds the text one character at a
  // time, remembers which character each folded unit came from, finds the
  // words in the folded run and marks the characters they belong to. "ß"
  // folds to two units and an accent to none, and both still land on the
  // letter the reader sees.
  //
  // Only what the card shows is marked. The match itself may sit deeper in
  // the post than the excerpt reaches; then nothing is marked, which is
  // true -- the word is not in these lines.
  function foldChar(ch) {
    return ch.normalize('NFKD').replace(/\p{Mn}/gu, '').toLowerCase()
      .replace(/[ßæœøđðþłħŧŋıς]/g, function (c) { return FOLD_MAP[c]; })
      .replace(/[ \t\n\r\f\v]/g, ' ');
  }

  function markTerms(text, terms) {
    var chars = Array.from(text || '');
    if (!terms.length || !chars.length) return escapeHtml(text || '');
    var folded = '';
    var owner = [];
    chars.forEach(function (ch, i) {
      var units = Array.from(foldChar(ch));
      units.forEach(function (u) { folded += u; owner.push(i); });
    });
    // An accent written as a character of its own -- how an import or a
    // Mac may keep "ě" -- folds to nothing, so it owned no unit and no
    // word could mark it: the mark closed in front of it and opened again
    // behind, one word as three pieces with its accents left outside.
    // Such a character belongs to the letter before it.
    var joins = chars.map(function (ch, i) { return i > 0 && foldChar(ch) === '' && /\p{M}/u.test(ch); });
    // Counted in code points on both sides, so a pair of surrogates in the
    // folded run cannot shift every mark after it by one.
    var run = Array.from(folded);
    var marked = [];
    terms.forEach(function (term) {
      var want = Array.from(term);
      if (!want.length) return;
      for (var at = 0; at + want.length <= run.length; at++) {
        var hit = true;
        for (var k = 0; k < want.length; k++) { if (run[at + k] !== want[k]) { hit = false; break; } }
        if (hit) { for (var j = 0; j < want.length; j++) marked[owner[at + j]] = true; }
      }
    });
    var out = '';
    var open = false;
    chars.forEach(function (ch, i) {
      if (joins[i]) marked[i] = marked[i - 1];
      if (marked[i] && !open) { out += '<mark>'; open = true; }
      if (!marked[i] && open) { out += '</mark>'; open = false; }
      out += escapeHtml(ch);
    });
    return open ? out + '</mark>' : out;
  }

  function resultsUnit(n) {
    if (n === 1) return i18n.results_one;
    if (n < 5) return i18n.results_few;
    return i18n.results_many;
  }

  function renderResults(container, hits, query, archivePending, archiveFailed) {
    if (!query.trim()) {
      container.innerHTML = '<p class="search-status">' + escapeHtml(i18n.search_prompt || '') + '</p>';
      return;
    }
    var archiveNote = archivePending ? ' <span class="search-archive-pending">' + i18n.searching_archive + '</span>' : '';
    if (archiveFailed) archiveNote = ' <span class="search-archive-failed">' + escapeHtml(i18n.archive_unavailable) + '</span>';
    if (!hits.length) {
      var noResults = archivePending
        ? i18n.no_results_pending + archiveNote
        : i18n.no_results_final + archiveNote + i18n.try_other_words;
      container.innerHTML = '<p class="search-status">' + noResults + '</p>';
      return;
    }
    // Everything found is counted; only the best of it is drawn. A query of
    // two letters matches most of a four-thousand-post archive, and the page
    // used to build a card for every one of them -- tens of thousands of
    // nodes, in one innerHTML, on every keystroke. Fifty is more than anyone
    // reads and few enough that the browser does not notice.
    //
    // The cap is only honest because the list is ranked (see rankHits): the
    // fifty shown are the fifty best answers, not the fifty most recent
    // posts that happen to contain the word. The count still says how many
    // there were, so nobody is told a smaller number than the truth.
    var capNote = hits.length > RESULT_LIMIT
      ? String(i18n.results_capped || '').replace('%{count}', RESULT_LIMIT)
      : '';
    // The number and its word are a span each: beside a heading that says
    // "blog.sh" a skin wants just "10", the way every other listing's
    // heading carries its count, and one run of text could not be split.
    var html = '<p class="search-status"><span class="search-count">' + hits.length + '</span> ' +
               '<span class="search-unit">' + escapeHtml(resultsUnit(hits.length)) + '</span>' +
               capNote + archiveNote + '</p>';
    var terms = parseQueryTokens(query).filter(function (x) { return !x.neg; }).map(function (x) { return x.t; });
    html += hits.slice(0, RESULT_LIMIT).map(function (p) {
      // Array.from, not slice: slice counts UTF-16 units, so a cut that
      // landed inside an emoji ended the heading with a replacement
      // character. And a post with neither title nor text used to render a
      // card whose heading was the empty string -- a date with nothing to
      // click. Its date is the name it is known by everywhere else.
      var chars = Array.from(p.excerpt || '');
      var fromText = chars.length > 60 ? chars.slice(0, 60).join('') + '…' : chars.join('');
      var title = p.title || fromText || p.date;
      return (
        '<div class="card post-list-item search-result">' +
          '<p class="meta">' + escapeHtml(p.date) + '</p>' +
          '<h2><a href="' + escapeHtml(p.url) + '">' + markTerms(title, terms) + '</a></h2>' +
          '<p>' + markTerms(p.excerpt, terms) + '</p>' +
        '</div>'
      );
    }).join('');
    container.innerHTML = html;
  }

  document.addEventListener('DOMContentLoaded', function () {
    var input = document.getElementById('search-q');
    var results = document.getElementById('search-results');
    var heading = document.querySelector('.listing-heading--search');
    var headingValue = document.getElementById('search-heading-value');
    if (!input) return;

    // The word "Search" is already in the markup; this only fills the query
    // next to it and tells the stylesheet there is one. Overwriting the whole
    // heading -- what this did before -- deleted that word from the
    // accessibility tree the moment somebody typed, leaving a page whose only
    // heading was their own search terms.
    function setSearchHeading(value) {
      if (!headingValue) return;
      var text = String(value == null ? '' : value).trim();
      headingValue.textContent = text;
      if (heading) heading.classList.toggle('has-query', text.length > 0);
    }

    var q = new URLSearchParams(window.location.search).get('q') || '';
    if (results) input.value = q;
    setSearchHeading(q);
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
      fetch((i18n.lang_root || '') + '/search-index-archive.json')
        .then(function (r) { return r.json(); })
        .then(function (data) {
          archiveIndex = data;
          archiveState = 'loaded';
          run();
        })
        // A failed fetch used to be swallowed here. On a real archive the
        // recent index is a ninth of the whole, so search went on answering
        // from 11% of the site with a count that read as final -- the reader
        // was told "3 results" for a word with thirty. It says so now, and
        // the next keystroke tries again rather than giving up for the life
        // of the page.
        .catch(function () { archiveState = 'failed'; run(); });
    }

    // The address follows the query. ?q= was read on the way in and never
    // written again, so a search existed only on the screen of whoever ran
    // it: it could not be sent to anybody, bookmarked, or -- the one that
    // stings -- come back to. Following a result and pressing Back landed
    // on an empty search box, with the query to type in all over again.
    //
    // replaceState, not pushState: at one entry per keystroke Back would
    // walk the query backwards a letter at a time and never leave the page.
    // /search/ stays one entry in the history whose address happens to be
    // current, which is what makes coming back to it restore the search.
    function syncAddress(query) {
      var url = new URL(window.location.href);
      if (query.trim()) url.searchParams.set('q', query);
      else url.searchParams.delete('q');
      // Only when it actually moved: run() is called again when the archive
      // arrives, and browsers put a ceiling on how often a page may rewrite
      // its own address.
      if (url.href !== window.location.href) window.history.replaceState(null, '', url.href);
    }

    function run() {
      if (!index) return;
      var query = input.value;
      loadArchiveIfNeeded(query);
      setSearchHeading(query);
      syncAddress(query);
      var tokens = parseQueryTokens(query);
      var hits = rankHits(searchMatches(combinedIndex(), tokens), tokens);
      renderResults(results, hits, query, archiveState === 'loading', archiveState === 'failed');
      // One retry per query: 'failed' would otherwise stop
      // loadArchiveIfNeeded from ever asking again.
      if (archiveState === 'failed') archiveState = 'idle';
    }

    results.innerHTML = '<p class="search-status">' + escapeHtml(i18n.loading_index) + '</p>';
    fetch((i18n.lang_root || '') + '/search-index.json')
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
