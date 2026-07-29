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
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });
  });
})();
