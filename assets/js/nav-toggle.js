(function () {
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.nav-toggle').forEach(function (btn) {
      var nav = btn.closest('nav');

      function set(open) {
        nav.classList.toggle('nav-open', open);
        btn.setAttribute('aria-expanded', open ? 'true' : 'false');
      }

      btn.addEventListener('click', function () {
        set(!nav.classList.contains('nav-open'));
      });

      // The open menu is 700 of the 812px a phone has, and until now the
      // only way back out of it was the same 40px button that opened it --
      // no Escape, no tapping the page. Both are what every other menu on a
      // phone answers to, and a reader who has decided against the menu
      // reaches for one of them before hunting for the button again.
      //
      // Escape hands focus back to the button rather than leaving it
      // wherever the menu was: the reader is on a keyboard, and the button
      // is where they were before they opened it.
      document.addEventListener('keydown', function (e) {
        if (e.key !== 'Escape' || !nav.classList.contains('nav-open')) return;
        set(false);
        btn.focus();
      });

      // The button lives inside the nav, so its own click lands in the
      // "inside" branch here and the toggle above is left to decide what to
      // do about it -- otherwise opening the menu would close it again in
      // the same click. A page with two menus (a repeated bottom one) gets
      // one of these per menu, and each closes only its own.
      document.addEventListener('click', function (e) {
        if (!nav.classList.contains('nav-open') || nav.contains(e.target)) return;
        set(false);
      });
    });
  });
})();
