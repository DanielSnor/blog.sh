// Sidebar widgets. All three read JSON from the same origin -- the server
// fetches the data (lib/sidebar.rb, cron via ./refresh-sidebar.sh), not the
// visitor's browser. Previously toots and commits were fetched directly by
// the client from the configured Mastodon instance and api.github.com: 4+
// requests to third-party APIs on every page view, GitHub's 60/hour-per-IP
// rate limit, and the visitor's IP going to those third parties.
(function () {
  var esc = window.Blog.escapeHtml;

  function block(date, contentHtml, url) {
    return (
      '<div class="last">' +
        '<div class="last-date">' + esc(date) + '</div>' +
        '<div class="last-content">' + contentHtml + '</div>' +
        '<a href="' + esc(url) + '" target="_blank" rel="noopener">' +
          esc(String(url).replace(/^https?:\/\//, '')) +
        '</a>' +
      '</div>'
    );
  }

  var WIDGETS = [
    {
      id: 'last-toots',
      src: '/toots.json',
      // The toot content is HTML already sanitized by Mastodon and is
      // deliberately inserted as HTML -- otherwise paragraphs and links
      // would show up as raw markup.
      render: function (it) { return block(it.date, it.content, it.url); }
    },
    {
      id: 'last-pixelfeds',
      src: '/pixelfed.json',
      render: function (it) {
        var photo = it.image
          ? '<img class="pixelfed-thumb" src="' + esc(it.image) + '" alt="' + esc(it.title) + '" loading="lazy">'
          : '';
        return block(it.date, '<p>' + esc(it.title) + '</p>' + photo, it.url);
      }
    },
    {
      id: 'last-commits',
      src: '/commits.json',
      render: function (it) {
        return block(it.date, '<p><strong>' + esc(it.repo) + '</strong>: ' + esc(it.message) + '</p>', it.url);
      }
    }
  ];

  document.addEventListener('DOMContentLoaded', function () {
    WIDGETS.forEach(function (widget) {
      var container = document.getElementById(widget.id);
      if (!container) return; // widget not configured for this site -- its card wasn't rendered at all

      fetch(widget.src)
        .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
        .then(function (items) {
          if (!items || !items.length) return Promise.reject('empty');
          container.innerHTML = items.map(widget.render).join('');
          return null;
        })
        .catch(function () {
          var card = container.closest('.card');
          if (card) card.style.display = 'none';
        });
    });
  });
})();
