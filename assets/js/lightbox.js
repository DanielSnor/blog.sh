(function () {
  document.addEventListener('DOMContentLoaded', function () {
    var i18n = window.BLOG_I18N || {};
    var esc = window.Blog.escapeHtml;
    // The images this can open. Named once, because three things now need to
    // agree on it: the click, the keyboard, and what gets made focusable.
    var OPENABLE = '.content figure img, .photo-grid img';

    var overlay = document.createElement('div');
    overlay.className = 'lightbox-overlay';
    // While it is up, this is the page: it covers everything, the body
    // cannot scroll, and Tab is kept inside it. A screen reader has to be
    // told the same thing, or it goes on reading the article underneath.
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    if (i18n.lightbox_label) overlay.setAttribute('aria-label', i18n.lightbox_label);
    overlay.innerHTML =
      '<button class="lightbox-close" type="button" aria-label="' + esc(i18n.lightbox_close) + '">&times;</button>' +
      '<button class="lightbox-nav lightbox-prev" type="button" aria-label="' + esc(i18n.lightbox_prev) + '">&lsaquo;</button>' +
      '<img alt="">' +
      '<button class="lightbox-nav lightbox-next" type="button" aria-label="' + esc(i18n.lightbox_next) + '">&rsaquo;</button>';
    document.body.appendChild(overlay);

    var img = overlay.querySelector('img');
    var closeBtn = overlay.querySelector('.lightbox-close');
    var prevBtn = overlay.querySelector('.lightbox-prev');
    var nextBtn = overlay.querySelector('.lightbox-next');
    var group = [];
    var index = 0;
    var opener = null;

    // An image that opens something is a button, and until now it was one
    // only for a mouse: no tab stop, nothing to press, nothing announced. It
    // is done here rather than in the built markup on purpose -- with the
    // script absent or broken the image is a picture again, and a picture
    // should not advertise itself as something to press. The alt text is the
    // name; where there is none the button would have no name at all, so it
    // borrows one.
    Array.prototype.forEach.call(document.querySelectorAll(OPENABLE), function (el) {
      el.tabIndex = 0;
      el.setAttribute('role', 'button');
      if (!el.getAttribute('alt') && i18n.lightbox_open) el.setAttribute('aria-label', i18n.lightbox_open);
    });

    function show(i) {
      index = (i + group.length) % group.length;
      var target = group[index];
      img.src = target.currentSrc || target.src;
      img.alt = target.alt || '';
      var multi = group.length > 1;
      prevBtn.style.display = multi ? 'flex' : 'none';
      nextBtn.style.display = multi ? 'flex' : 'none';
    }

    // Only what is actually on screen: the two arrows are display:none for a
    // single image, and a Tab that lands on a hidden button goes nowhere.
    function controls() {
      return Array.prototype.filter.call(overlay.querySelectorAll('button'), function (b) {
        return getComputedStyle(b).display !== 'none';
      });
    }

    // Tab cycles within the overlay instead of walking off into the article
    // behind it -- which is the article this was opened from, still there,
    // still focusable, and completely invisible under a black screen.
    function trapTab(e) {
      var items = controls();
      if (!items.length) return;
      var first = items[0];
      var last = items[items.length - 1];
      var inside = overlay.contains(document.activeElement);
      if (e.shiftKey && (!inside || document.activeElement === first)) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && (!inside || document.activeElement === last)) {
        e.preventDefault();
        first.focus();
      }
    }

    function open(clicked) {
      // Remembered so that closing puts the reader back on the image they
      // opened, rather than at the top of the document with the page they
      // were reading somewhere below.
      opener = clicked;
      var container = clicked.closest('.content') || clicked.parentElement;
      group = Array.prototype.slice.call(container.querySelectorAll('img'));
      var idx = group.indexOf(clicked);
      show(idx === -1 ? 0 : idx);
      overlay.classList.add('visible');
      document.body.style.overflow = 'hidden';
      closeBtn.focus();
    }

    function close() {
      overlay.classList.remove('visible');
      document.body.style.overflow = '';
      // Removed rather than set to "": an empty src is a relative URL that
      // resolves to the page itself, which some browsers duly request again.
      img.removeAttribute('src');
      group = [];
      if (opener) {
        opener.focus();
        opener = null;
      }
    }

    document.addEventListener('click', function (e) {
      var target = e.target.closest(OPENABLE);
      if (!target) return;
      e.preventDefault();
      open(target);
    });

    overlay.addEventListener('click', close);
    prevBtn.addEventListener('click', function (e) { e.stopPropagation(); show(index - 1); });
    nextBtn.addEventListener('click', function (e) { e.stopPropagation(); show(index + 1); });

    document.addEventListener('keydown', function (e) {
      if (overlay.classList.contains('visible')) {
        if (e.key === 'Escape') close();
        else if (e.key === 'ArrowLeft') show(index - 1);
        else if (e.key === 'ArrowRight') show(index + 1);
        else if (e.key === 'Tab') trapTab(e);
        return;
      }
      // Enter and Space are what a button answers to, and the images are
      // buttons now. Space would otherwise scroll the page out from under
      // the picture that is about to open.
      if (e.key !== 'Enter' && e.key !== ' ') return;
      var target = e.target.closest ? e.target.closest(OPENABLE) : null;
      if (!target) return;
      e.preventDefault();
      open(target);
    });
  });
})();
