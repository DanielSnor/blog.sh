(function () {
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.nav-toggle').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var nav = btn.closest('nav');
        var open = nav.classList.toggle('nav-open');
        btn.setAttribute('aria-expanded', open ? 'true' : 'false');
      });
    });
  });
})();
