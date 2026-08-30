(function () {
  // Built here rather than shipped in the HTML, the way the tag index's
  // sort bar is: without this script the button would be a control that
  // does nothing, and a code block is perfectly readable without one.
  //
  // Three conditions, and all of them are asked BEFORE anything is drawn.
  // The clipboard API exists only in a secure context, so on an http://
  // install -- which blog.sh supports -- navigator.clipboard is undefined
  // and a button that cannot copy must not be offered. There is no
  // fallback to the old execCommand path on purpose: it needs a selection
  // to be made and undone in the page, and a copy that half works is
  // worse than one the reader never sees.
  if (!navigator.clipboard || !navigator.clipboard.writeText || !window.isSecureContext) return;

  var i18n = window.BLOG_I18N || {};
  var LABEL = i18n.copy_code || 'Copy text';
  var DONE_LABEL = i18n.copy_code_done || 'Copied';
  var FAILED_LABEL = i18n.copy_code_failed || 'Could not copy';
  // Long enough to be seen, short enough not to look like a state the
  // page is stuck in.
  var SHOWN = 1400;

  // Only the blocks the engine renders as CODE. A chat is a <dl>, and the
  // fallback for an unknown block type is a bare <pre> -- offering to copy
  // the engine's own error state is not what anybody asked for. Inline
  // code is a <code> without a <pre> and is left alone.
  var blocks = document.querySelectorAll('pre.code-block');
  if (!blocks.length) return;

  var COPY = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" ' +
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<rect x="9" y="9" width="11" height="11" rx="2"/>' +
    '<path d="M5 15V5a2 2 0 0 1 2-2h8"/></svg>';
  var DONE = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" ' +
    'stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<path d="M20 6L9 17l-5-5"/></svg>';

  Array.prototype.forEach.call(blocks, function (pre) {
    var code = pre.querySelector('code');
    if (!code) return;

    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'copy-code';
    // The name is the whole label: the button shows an icon, and hovering
    // is not how a screen reader or a keyboard reaches it.
    button.setAttribute('aria-label', LABEL);
    button.title = LABEL;
    button.innerHTML = COPY;

    var timer = null;
    button.addEventListener('click', function () {
      // textContent, not innerText: the block is preformatted and
      // innerText would hand back what the LAYOUT did to it -- collapsed
      // runs, and on a wrapped line a break the author never typed.
      navigator.clipboard.writeText(code.textContent).then(function () {
        button.innerHTML = DONE;
        button.classList.add('copy-code--done');
        // The icon is the feedback for anybody who can see it; the name
        // is the feedback for anybody who cannot. Without this a screen
        // reader hears the same "Copy text" whether the copy happened or
        // was refused, which is no feedback at all.
        button.setAttribute('aria-label', DONE_LABEL);
        button.title = DONE_LABEL;
        clearTimeout(timer);
        timer = setTimeout(function () {
          button.innerHTML = COPY;
          button.classList.remove('copy-code--done');
          button.setAttribute('aria-label', LABEL);
          button.title = LABEL;
        }, SHOWN);
      }).catch(function () {
        // A refused clipboard (a permission policy, a browser that asks
        // and was told no) must not look like a copy that worked. No
        // message appears -- an error in the corner of a code block is
        // worse than a second attempt -- but the button says so to
        // anybody who asks it, and stops saying it once the reader has
        // had time to try again.
        button.setAttribute('aria-label', FAILED_LABEL);
        button.title = FAILED_LABEL;
        clearTimeout(timer);
        timer = setTimeout(function () {
          button.setAttribute('aria-label', LABEL);
          button.title = LABEL;
        }, SHOWN);
      });
    });

    // The button goes in a WRAPPER around the block, never inside it.
    // A <pre> that scrolls is its own scroll container, and an absolutely
    // positioned child of it is placed against the CONTENT rather than
    // against the box: on a long command the button rode across the code
    // as the reader scrolled and ended up outside the block entirely.
    // The wrapper does not scroll, so the button stays in its corner.
    var wrap = document.createElement('div');
    wrap.className = 'code-wrap';
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(pre);
    wrap.appendChild(button);
  });
})();
