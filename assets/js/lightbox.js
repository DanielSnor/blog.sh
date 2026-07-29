(function () {
  document.addEventListener('DOMContentLoaded', function () {
    var i18n = window.BLOG_I18N || {};
    var esc = window.Blog.escapeHtml;
    var overlay = document.createElement('div');
    overlay.className = 'lightbox-overlay';
    overlay.innerHTML =
      '<button class="lightbox-close" type="button" aria-label="' + esc(i18n.lightbox_close) + '">&times;</button>' +
      '<button class="lightbox-nav lightbox-prev" type="button" aria-label="' + esc(i18n.lightbox_prev) + '">&lsaquo;</button>' +
      '<img alt="">' +
      '<button class="lightbox-nav lightbox-next" type="button" aria-label="' + esc(i18n.lightbox_next) + '">&rsaquo;</button>';
    document.body.appendChild(overlay);

    var img = overlay.querySelector('img');
    var prevBtn = overlay.querySelector('.lightbox-prev');
    var nextBtn = overlay.querySelector('.lightbox-next');
    var group = [];
    var index = 0;

    function show(i) {
      index = (i + group.length) % group.length;
      var target = group[index];
      img.src = target.currentSrc || target.src;
      img.alt = target.alt || '';
      var multi = group.length > 1;
      prevBtn.style.display = multi ? 'flex' : 'none';
      nextBtn.style.display = multi ? 'flex' : 'none';
    }

    function open(clicked) {
      var container = clicked.closest('.content') || clicked.parentElement;
      group = Array.prototype.slice.call(container.querySelectorAll('img'));
      var idx = group.indexOf(clicked);
      show(idx === -1 ? 0 : idx);
      overlay.classList.add('visible');
      document.body.style.overflow = 'hidden';
    }

    function close() {
      overlay.classList.remove('visible');
      document.body.style.overflow = '';
      img.src = '';
      group = [];
    }

    document.addEventListener('click', function (e) {
      var target = e.target.closest('.content figure img, .photo-grid img');
      if (!target) return;
      e.preventDefault();
      open(target);
    });

    overlay.addEventListener('click', close);
    prevBtn.addEventListener('click', function (e) { e.stopPropagation(); show(index - 1); });
    nextBtn.addEventListener('click', function (e) { e.stopPropagation(); show(index + 1); });

    document.addEventListener('keydown', function (e) {
      if (!overlay.classList.contains('visible')) return;
      if (e.key === 'Escape') close();
      if (e.key === 'ArrowLeft') show(index - 1);
      if (e.key === 'ArrowRight') show(index + 1);
    });
  });
})();
