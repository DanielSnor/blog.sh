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
    },
    {
      id: 'last-bluesky',
      src: '/bluesky.json',
      // Bluesky post text is plain text (not sanitized HTML like
      // Mastodon's) -- escaped wholesale, newlines become <br>.
      render: function (it) {
        return block(it.date, '<p>' + esc(it.text).replace(/\n/g, '<br>') + '</p>', it.url);
      }
    },
    {
      id: 'last-rss',
      src: '/rss.json',
      render: function (it) {
        return block(it.date, '<p>' + esc(it.title) + '</p>', it.url);
      }
    }
  ];

// On this day (lib/on_this_day.rb). Not one of the list above: its file
// is this LANGUAGE's (the card names it in data-src), and what it holds is
// a whole day cut into windows -- the card shows the one the clock is in.
// A file from another day has no window for now, so a cron that stopped
// turning the day over hides the card rather than showing yesterday as
// today. Titles and addresses are escaped like every other foreign string
// here, even though the build wrote them: a title is whatever the author
// typed, and that includes a "<".
var i18n = window.BLOG_I18N || {};

function yearsAgo(n) {
  var one = i18n.on_this_day_ago_one || 'a year ago';
  var other = i18n.on_this_day_ago_other || '%{n} years ago';
  return n === 1 ? one : other.replace('%{n}', String(n));
}

function dayRow(it) {
  return (
    '<div class="last">' +
      '<div class="last-date">' + esc(yearsAgo(it.ago)) + ' · ' + esc(String(it.year)) + '</div>' +
      '<div class="last-content"><p><a href="' + esc(it.url) + '">' + esc(it.title) + '</a></p></div>' +
    '</div>'
  );
}

function wholeDay(all) {
  var label = (i18n.on_this_day_all || 'Everything from this day (%{count})').replace('%{count}', String(all.length));
  return (
    '<details class="on-this-day-all"><summary>' + esc(label) + '</summary><ul>' +
      all.map(function (it) {
        return '<li><span class="last-date">' + esc(String(it.year)) + '</span> ' +
               '<a href="' + esc(it.url) + '">' + esc(it.title) + '</a></li>';
      }).join('') +
    '</ul></details>'
  );
}

function onThisDay() {
  var box = document.getElementById('on-this-day');
  if (!box) return; // the site has not switched the card on

  var card = box.closest('.card');
  fetch(box.getAttribute('data-src') || '/on-this-day.json')
    .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
    .then(function (data) {
      var now = Date.now();
      var current = ((data && data.windows) || []).filter(function (w) {
        return Date.parse(w.from) <= now && now < Date.parse(w.to);
      })[0];
      if (!current || !current.rows || !current.rows.length) return Promise.reject('nothing today');
      var all = data.all || [];
      box.innerHTML = current.rows.map(dayRow).join('') +
                      (all.length > current.rows.length ? wholeDay(all) : '');
      return null;
    })
    .catch(function () {
      if (card) card.style.display = 'none';
    });
}

  document.addEventListener('DOMContentLoaded', function () {
    onThisDay();
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
