// assets/js/share.js -- the one share control that cannot be a link.
//
// Bluesky has a single address to send a reader to, and so does mail. The
// fediverse has as many as it has instances, and the page has no way to
// know which one is the reader's -- so this asks, once, and remembers the
// answer in this browser. No third-party redirector: that would put an
// outside service on every post page, and in the way of every share.
//
// The button is rendered HIDDEN and shown here, so a reader without
// JavaScript is not left with a control that does nothing.
(function () {
  'use strict';
  var KEY = 'blogsh:mastodon-instance';
  // A host and nothing else: what somebody types is as likely to be
  // "https://mastodon.social/@me" as "mastodon.social", and both should
  // work. Anything that is not a hostname is refused rather than pasted
  // into an address.
  // What somebody types when asked which instance they are on, reduced to
  // the host. It has to be generous, because the ways people write their
  // own address are many and all of them are meant:
  //
  //   mastodon.social              the answer to the question
  //   https://mastodon.social/@me  copied out of the address bar
  //   @me@mastodon.social          their handle, written in full
  //   me@mastodon.social           their handle, the way most people
  //                                actually write it -- and the one this
  //                                used to refuse
  //
  // Ports and non-ASCII labels are allowed too: an instance on :3000 is a
  // real instance, and refusing every accented domain is refusing a good
  // part of the fediverse. Every refusal here was SAFE -- nothing opened,
  // nothing stored -- but a reader turned away is a reader turned away.
  function host(answer) {
    var value = String(answer || '').trim().replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
    // Anything up to the LAST @ is a handle, with or without its leading
    // one. Splitting on the last one, because a handle may not contain a
    // second and an address may not contain any.
    var at = value.lastIndexOf('@');
    if (at !== -1) { value = value.slice(at + 1); }
    if (!value || value.indexOf(' ') !== -1) { return null; }
    // A dotted name, optionally with a port. Unicode letters allowed;
    // what is refused is punctuation, schemes and whitespace.
    return /^[^\s.:\/@]+(\.[^\s.:\/@]+)+(:\d{1,5})?$/.test(value) ? value : null;
  }
  function remembered() {
    try {
      return host(window.localStorage.getItem(KEY));
    } catch (e) {
      // A browser that refuses storage still gets to share; it is asked
      // every time, which is a smaller loss than not working at all.
      return null;
    }
  }
  function remember(value) {
    try {
      window.localStorage.setItem(KEY, value);
    } catch (e) { /* nothing to do about it, and nothing worth saying */ }
  }
  // The OS share sheet, where there is one. On a phone this IS Signal and
  // WhatsApp and Telegram and whatever else is installed, so one button
  // covers what a row of them could not -- and on a desktop, where the
  // API mostly does not exist, the button never appears rather than
  // opening nothing.
  if (navigator.share) {
    document.querySelectorAll('[data-share-system]').forEach(function (button) {
      button.hidden = false;
      button.addEventListener('click', function () {
        navigator.share({
          title: button.getAttribute('data-share-title') || '',
          url: button.getAttribute('data-share-url') || ''
        }).catch(function () { /* a reader who changes their mind is not an error */ });
      });
    });
  }

  // The universal one -- and only where there is a clipboard to write to.
  // The API exists in a secure context and nowhere else, so on an http://
  // install the button used to sit there and do nothing at all. The code
  // blocks' own copy button has refused to appear in that case since it
  // was written; this now does the same.
  if (navigator.clipboard && navigator.clipboard.writeText && window.isSecureContext) {
    document.querySelectorAll('[data-share-copy]').forEach(function (button) {
      // Read ONCE, here. Reading it at click time meant the second click
      // stored "copied" as the name to go back to, and the button was
      // called that for the rest of the page's life.
      var label = button.getAttribute('aria-label') || '';
      var done = button.getAttribute('data-share-done') || '';
      var failed = button.getAttribute('data-share-failed') || '';
      var timer = null;

      function say(text, isDone) {
        if (text) { button.setAttribute('aria-label', text); button.title = text; }
        button.classList.toggle('is-done', !!isDone);
        window.clearTimeout(timer);
        timer = window.setTimeout(function () {
          button.classList.remove('is-done');
          if (label) { button.setAttribute('aria-label', label); button.title = label; }
        }, 1500);
      }

      button.hidden = false;
      button.addEventListener('click', function () {
        navigator.clipboard.writeText(button.getAttribute('data-share-url') || '')
          .then(function () { say(done, true); },
                // A refused clipboard must not look like one that worked:
                // a permission policy, or a browser that asked and was
                // told no. Silence was the same answer as success.
                function () { say(failed, false); });
      });
    });
  }

  // Mastodon: the button opens a row on the page, and the row asks. A
  // prompt() was the first answer and it was wrong three ways -- it looks
  // like something the page did not make, browsers throttle it (none at
  // all in a background tab), and a dialog asking for the name of a server
  // is the shape people are taught not to trust.
  var ask = document.querySelector('[data-share-ask]');
  var field = ask && ask.querySelector('.share__ask-input');
  var error = ask && ask.querySelector('[data-share-error]');
  var change = document.querySelector('[data-share-change]');
  var pending = null;

  // Only worth offering once there is something to change.
  function showChange() {
    if (change) { change.hidden = !remembered(); }
  }

  function openAsk(text, by) {
    if (!ask) { return; }
    pending = text;
    opener = by;
    ask.hidden = false;
    if (by) { by.setAttribute('aria-expanded', 'true'); }
    if (field) {
      // Prefilled with what is stored, so changing it is editing rather
      // than remembering and retyping.
      field.value = remembered() || '';
      field.focus();
      field.select();
    }
  }

  function shareTo(instance, text) {
    window.open('https://' + instance + '/share?text=' + encodeURIComponent(text || ''),
                '_blank', 'noopener');
  }

  // Who opened the row, so closing it can hand focus back. Without this a
  // reader who pressed Escape -- or who shared and watched the row go --
  // was left with focus on an element that is no longer rendered, and the
  // next Tab started again from the top of the document.
  var opener = null;

  function closeAsk() {
    if (!ask) { return; }
    var wasInside = ask.contains(document.activeElement);
    ask.hidden = true;
    if (error) { error.hidden = true; }
    if (field) { field.removeAttribute('aria-invalid'); }
    document.querySelectorAll('[data-share-mastodon]').forEach(function (b) {
      b.setAttribute('aria-expanded', 'false');
    });
    if (change) { change.setAttribute('aria-expanded', 'false'); }
    // Only when focus was in the thing being closed: taking it from
    // somewhere else would be its own rudeness.
    if (wasInside && opener && !opener.hidden) { opener.focus(); }
    opener = null;
    pending = null;
  }

  document.querySelectorAll('[data-share-mastodon]').forEach(function (button) {
    button.hidden = false;
    button.addEventListener('click', function () {
      var text = button.getAttribute('data-share-text') || '';
      var known = remembered();
      if (known) { shareTo(known, text); return; }
      if (!ask) { return; }

      openAsk(text, button);
    });
  });

  // The way back. It carries the text of the FIRST Mastodon control on
  // the page, which is the only post this block is about.
  if (change) {
    change.addEventListener('click', function () {
      var button = document.querySelector('[data-share-mastodon]');
      change.setAttribute('aria-expanded', 'true');
      openAsk(button ? button.getAttribute('data-share-text') || '' : '', change);
    });
    showChange();
  }

  if (ask) {
    ask.addEventListener('submit', function (event) {
      event.preventDefault();
      var instance = host(field && field.value);
      if (!instance) {
        // Said on the page, not thrown away: a field that clears itself
        // and does nothing is a field nobody tries twice.
        if (error) { error.hidden = false; }
        if (field) { field.setAttribute('aria-invalid', 'true'); field.focus(); }
        return;
      }
      remember(instance);
      showChange();
      var text = pending;
      closeAsk();
      // Nothing to open when the row was reached to CHANGE the answer
      // rather than to share: pending is empty then only if there was no
      // Mastodon button at all, which cannot happen while this row exists.
      if (text) { shareTo(instance, text); }
    });
    ask.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') { closeAsk(); }
    });
  }
  // Last: the block itself. Three of its controls only appear if the
  // browser co-operates, so a block made only of those can be a heading
  // over an empty row -- and one whose controls all turned up must not
  // stay hidden. Decided here, once, when everything else has had its say.
  document.querySelectorAll('.share').forEach(function (block) {
    var drawn = Array.prototype.filter.call(
      block.querySelectorAll('.share__link'), function (el) { return !el.hidden; }
    ).length;
    block.hidden = drawn === 0;
  });
})();
