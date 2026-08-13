(function () {
  var THRESHOLD = 300;

  document.addEventListener('DOMContentLoaded', function () {
    var btn = document.getElementById('scroll-top');
    if (!btn) return;

    function update() {
      btn.classList.toggle('visible', window.scrollY > THRESHOLD);
    }

    window.addEventListener('scroll', update);
    update();

    btn.addEventListener('click', function () {
      // The one piece of real movement on the site, so it asks whether the
      // reader wants any. site.css takes the fades out under the same
      // preference but cannot take this out: scroll-behavior governs
      // scrolling the browser decides on, not a scroll asked for here.
      // Asked at the click rather than at load, because the system setting
      // can change while the page is open and matchMedia answers for the
      // moment it is asked.
      var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      window.scrollTo({ top: 0, behavior: reduced ? 'auto' : 'smooth' });
    });
  });
})();
