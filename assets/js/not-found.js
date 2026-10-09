// not-found.js -- the 404 page, told which address it stands in for.
//
// /404.html is one file for every address the site does not have, so the
// build cannot know what was asked for. The browser can: the address is
// still in the bar. Two things are read out of it.
//
// The words. "/posts/2019/vylet-na-bezdez/" is somebody looking for
// "vylet na bezdez", and the page's search field is filled with exactly
// that -- the last part of the address that holds a word, its dashes
// turned to spaces. The search does not mind missing diacritics, so a
// post that moved is usually one Enter away. Nothing is searched until the
// reader asks: the field is an offer, not a redirect.
//
// The year. An address that names a year the archive has a page for gets
// the pill that leads there. The build writes one such pill per year,
// hidden; this shows the one that matches and leaves the rest alone, so
// nothing here can point at a year without a page.
//
// Without this file the page still works: an empty field and the pills
// that are always there.
(function () {
  'use strict';

  // The parts of an address a reader would not have typed as a word: the
  // engine's own folders and the file a server adds.
  var FURNITURE = { posts: true, page: true, tag: true, type: true, series: true, archive: true, index: true };

  function decoded(part) {
    // An address cut off in the middle of an escape (%E2%8) is not an
    // error worth dying of on a page that exists to help -- and what is
    // left of it is not a word either: "%E2%8" in the search field is
    // noise with a letter in it. Such a part is passed over.
    try { return decodeURIComponent(part); } catch (e) { return ''; }
  }

  function wordsOf(part) {
    return decoded(part)
      .replace(/\.[a-z0-9]{2,5}$/i, '')
      .replace(/[-_+.]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function fromAddress(pathname, langs) {
    var parts = pathname.split('/').filter(function (p) { return p !== ''; });
    // The folder of a language the site publishes is where the reader
    // was, not what they were after: /en/posts/2019/ has no word in it,
    // and "en" in a search box finds nothing anybody meant.
    if (parts.length && langs.indexOf(parts[0].toLowerCase()) !== -1) parts.shift();
    var words = '';
    for (var i = parts.length - 1; i >= 0 && !words; i--) {
      var candidate = wordsOf(parts[i]);
      // A part with no letter in it is a number -- a year, a month, an id --
      // and searching for "05" finds nothing anybody meant.
      if (/[^\d\s]/.test(candidate) && !FURNITURE[candidate.toLowerCase()]) words = candidate;
    }
    var year = null;
    parts.forEach(function (p) { if (!year && /^(19|20)\d\d$/.test(p)) year = p; });
    return { words: words.slice(0, 80), year: year };
  }

  document.addEventListener('DOMContentLoaded', function () {
    var field = document.getElementById('not-found-q');
    if (!field) return;

    var langs = (field.getAttribute('data-langs') || '').split(' ').filter(function (l) { return l !== ''; });
    var asked = fromAddress(window.location.pathname, langs);
    // Only into an empty field: a browser that restored what the reader
    // had typed before going back knows better than the address does.
    if (asked.words && !field.value) field.value = asked.words;

    if (asked.year) {
      var pills = document.querySelectorAll('.not-found-link--year');
      Array.prototype.forEach.call(pills, function (pill) {
        if (pill.getAttribute('data-year') === asked.year) pill.hidden = false;
      });
    }
  });
})();
