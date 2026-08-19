(function () {
  var root = document.documentElement;
  var i18n = window.BLOG_I18N || {};

  // Sun (U+2600) and moon (U+263E), each followed by U+FE0E to force text
  // presentation. Written as escapes on purpose: that selector is invisible in
  // an editor and gets dropped by careless copy-paste, and without it phones
  // render these as full-colour emoji that ignore the button's own colour.
  var SYMBOL = {
    auto: '\u2600\uFE0E/\u263E\uFE0E',
    light: '\u2600\uFE0E',
    dark: '\u263E\uFE0E'
  };
  var LABEL = { auto: i18n.theme_auto, light: i18n.theme_light, dark: i18n.theme_dark };

  function system() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  // Anything else in storage (a stale value, someone poking at devtools) is
  // treated as "no choice" rather than written back into data-theme, where it
  // would match neither the light block nor the dark one.
  function saved() {
    var v = localStorage.getItem('theme');
    return v === 'light' || v === 'dark' ? v : null;
  }

  // auto -> the opposite of what is on screen -> what the system says -> auto.
  // The first step is the opposite rather than a fixed light-then-dark cycle
  // because a reader whose system is already light would otherwise click
  // "light" and see nothing change -- and a button that does nothing on its
  // first press reads as broken. Storing the system's own value as step two
  // is what makes step three (dropping back to auto) visually quiet instead
  // of a second flip.
  function next(state) {
    if (!state) return system() === 'dark' ? 'light' : 'dark';
    if (state !== system()) return system();
    return null;
  }

  function apply(state) {
    if (state) {
      root.setAttribute('data-theme', state);
      localStorage.setItem('theme', state);
    } else {
      // The point of the whole cycle: without removing the key there is no way
      // back to following the system, short of clearing the site's data.
      root.removeAttribute('data-theme');
      localStorage.removeItem('theme');
    }
  }

  function paint(btn, state) {
    var key = state || 'auto';
    btn.textContent = SYMBOL[key];
    if (LABEL[key]) {
      btn.title = LABEL[key];
      btn.setAttribute('aria-label', LABEL[key]);
    }
  }

  function wire() {
    var btn = document.getElementById('theme-toggle');
    if (!btn) return;
    paint(btn, saved());
    btn.addEventListener('click', function () {
      var state = next(saved());
      apply(state);
      paint(btn, state);
    });
  }

  apply(saved());

  // The layout puts this script after the button, so the element is normally
  // already there -- painting the symbol now instead of waiting for
  // DOMContentLoaded keeps a stored choice from showing the auto symbol first.
  if (document.getElementById('theme-toggle')) wire();
  else document.addEventListener('DOMContentLoaded', wire);
})();
